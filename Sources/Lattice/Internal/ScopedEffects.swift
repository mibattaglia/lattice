#if canImport(CasePaths)
    import CasePaths
#endif

/// The lens chain from the root state/action space down to one scope, composed step by step
/// by the mount walk. `When` extends it; every other node passes it through unchanged.
struct _ScopeLens<RootState, RootAction, State, Action> {
    /// Extracts the scope's state from the root; `nil` when a case anywhere on the chain has
    /// departed (or an optional is nil).
    let extract: (RootState) -> State?

    /// Writes through the chain into the root; leaves the root untouched when the chain is
    /// broken. (The handle factory pre-checks presence, so the broken-chain path is a
    /// belt-and-braces no-op, not a semantics carrier.)
    let write: (inout RootState, _ mutate: (inout State) -> Void) -> Void

    /// Embeds a scope action into the root action space through the case-path chain.
    let embedAction: (Action) -> RootAction
}

extension _ScopeLens where State == RootState, Action == RootAction {
    /// The root's own lens.
    static var identity: Self {
        Self(
            extract: { $0 },
            write: { root, mutate in mutate(&root) },
            embedAction: { $0 }
        )
    }
}

extension _ScopeLens {
    /// Struct scope: always present.
    func appending<ChildState, ChildAction>(
        state keyPath: WritableKeyPath<State, ChildState>,
        action toChildAction: AnyCasePath<Action, ChildAction>
    ) -> _ScopeLens<RootState, RootAction, ChildState, ChildAction> {
        .init(
            extract: { self.extract($0).map { $0[keyPath: keyPath] } },
            write: { root, mutate in
                self.write(&root) { mutate(&$0[keyPath: keyPath]) }
            },
            embedAction: { self.embedAction(toChildAction.embed($0)) }
        )
    }

    /// Enum-case or optional scope: presence can flip. Optionals compose through CasePaths'
    /// `Optional.some` case, so `When(state: \.destination.some.detail, …)` needs no special
    /// handling.
    func appending<ChildState, ChildAction>(
        state casePath: AnyCasePath<State, ChildState>,
        action toChildAction: AnyCasePath<Action, ChildAction>
    ) -> _ScopeLens<RootState, RootAction, ChildState, ChildAction> {
        .init(
            extract: { self.extract($0).flatMap(casePath.extract) },
            write: { root, mutate in
                self.write(&root) { state in
                    guard var child = casePath.extract(from: state) else { return }
                    mutate(&child)
                    state = casePath.embed(child)
                }
            },
            embedAction: { self.embedAction(toChildAction.embed($0)) }
        )
    }
}

/// Builds the update-phase/effect-phase handle pair for one tree node. Called once per node at
/// mount; the root passes `_ScopeLens.identity`. Every closure captures the root core weakly:
/// the host's strong reference is the core's lifetime, and a dead core reads as dismounted.
func _makeEffectsHandles<RootState, RootAction, State, Action>(
    core: LatticeCore<RootState, RootAction>,
    lens: _ScopeLens<RootState, RootAction, State, Action>,
    path: GraphPath
) -> Effects<State, Action> {
    // Last state successfully read through the lens. After the scope's case departs — or the
    // core is deallocated — a racing read returns this snapshot.
    var lastKnownState: State?

    let effectState = EffectState<State, Action>(
        path: path,
        _updateContext: { [weak core] in core?.updateContext },
        _modify: { [weak core] (mutate, fileID, line) throws(CancellationError) in
            guard let core, !core.isDismounted else {
                if !Task.isCancelled {
                    latticeReportIssue(
                        "An 'EffectState' handle tried to modify the state of a dismounted feature",
                        fileID: fileID, line: line
                    )
                }
                throw CancellationError()
            }
            // Presence pre-check. Single isolation domain + synchronous funnel: presence
            // cannot change between this check and the write below. A dropped mutation runs
            // no funnel pass — no transition detection, no projection diff.
            guard lens.extract(core.currentState) != nil else {
                // Normally already done by the funnel's transition detection when the case
                // departed; repeating it is idempotent and covers effects launched with a
                // stale handle.
                core.cancelTasks(withPrefix: path)
                #if DEBUG
                    _EffectsDiagnostics.droppedReentry(.modify, path: path, fileID: fileID, line: line)
                #endif
                return
            }
            // 'modify' throws only 'CancellationError' (dismounted), ruled out above.
            try? core.modify { root in
                lens.write(&root, mutate)
            }
        },
        _send: { [weak core] (action, fileID, line) throws(CancellationError) -> Task<Void, Never>? in
            guard let core, !core.isDismounted else {
                if !Task.isCancelled {
                    latticeReportIssue(
                        "An 'EffectState' handle tried to send an action to a dismounted feature",
                        fileID: fileID, line: line
                    )
                }
                throw CancellationError()
            }
            guard lens.extract(core.currentState) != nil else {
                core.cancelTasks(withPrefix: path)
                #if DEBUG
                    _EffectsDiagnostics.droppedReentry(.send, path: path, fileID: fileID, line: line)
                #endif
                return nil
            }
            // 'send' throws only 'CancellationError' (dismounted), ruled out above.
            return (try? core.send(lens.embedAction(action))) ?? nil
        },
        _state: { [weak core] in
            if let core {
                // Dismount cancels work but does not destroy state; reads stay live while
                // the core does.
                if core.isDismounted, !Task.isCancelled {
                    latticeReportIssue(
                        "An 'EffectState' handle tried to read the state of a dismounted feature"
                    )
                }
                if let state = lens.extract(core.currentState) {
                    lastKnownState = state
                    return state
                }
                if let lastKnownState {
                    // Case departed: the bucket is already cancelled; a racing read during
                    // wind-down gets the snapshot, silently.
                    return lastKnownState
                }
            } else if let lastKnownState {
                if !Task.isCancelled {
                    latticeReportIssue(
                        "An 'EffectState' handle tried to read the state of a dismounted feature"
                    )
                }
                return lastKnownState
            }
            fatalError("'EffectState.state' read for a scope whose state was never present")
        }
    )

    return Effects<State, Action>(
        path: path,
        _updateContext: { [weak core] in core?.updateContext },
        _isDismounted: { [weak core] in core?.isDismounted ?? true },
        _launch: { [weak core] location, operation in
            core?.launchEffect(path: path, location: location, operation: operation)
        },
        effectState: effectState,
        _bindEffectID: { [weak core] id in
            guard !id.storage.isBound else { return }
            let key = TaskKey(path: path, location: .id(ObjectIdentifier(id.storage)))
            id.storage.bind(
                isUpdatePhase: { [weak core] in core?.updateContext != nil },
                hasTasks: { [weak core] in core?.hasTasks(at: key) ?? false },
                currentTasks: { [weak core] in core?.currentTasks(at: key) ?? [] },
                cancelTasks: { [weak core] in core?.cancelTasks(at: key) }
            )
        }
    )
}
