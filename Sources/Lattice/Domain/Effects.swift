import IssueReporting

/// An effect operation. Starts on the owning model's isolation and resumes there after every
/// suspension; it is `nonisolated(nonsending)`, so it never hops to the global executor.
public typealias EffectOperation = nonisolated(nonsending) () async throws -> Void

/// The interactor's handle for asynchronous behaviour. A value type over the feature's runtime;
/// not `Sendable`, and never needs to be: it only runs on the model's isolation.
///
/// `perform` is legal only while `interact` runs. `state`, `modify` and `send` are legal only from
/// an effect. Both rules are reported through `reportIssue`; `perform` is also rejected at compile
/// time inside async contexts.
///
/// An effect delivers its result by modifying state; it sends an action only to start new effects,
/// run interactor logic or auto-cancel by action case:
///
/// ```swift
/// Interact { state, action, effects in
///     switch action {
///     case .refresh:
///         state.isRefreshing = true
///         effects.perform {
///             defer { try? effects.modify { $0.isRefreshing = false } }   // also runs when cancelled
///             let items = try await client.fetch()
///             try effects.modify { $0.items = items }
///         }
///     }
/// }
/// ```
public struct Effects<State, Action> {
    /// The committed state, untracked; `nil` when the runtime is gone or a case-scoped child is
    /// no longer active.
    let readState: () -> State?
    let isRoutingAction: () -> Bool
    /// The enum-tag path of this handle: the root action's tag, then one tag per `When` hop. Keys
    /// the handle's anonymous effects for auto-cancel.
    let path: [Int]
    /// One entry per `When` hop (its key path or case key path). Scopes the handle's `@EffectID`
    /// keys.
    let scopePath: [AnyHashable]
    let enqueue: ([Int], [AnyHashable], EffectID.Key?, @escaping EffectOperation) -> Void
    let enqueueCancel: ([AnyHashable], EffectID.Key) -> Void
    let isRunningKey: ([AnyHashable], EffectID.Key) -> Bool
    /// Registers a child path as an auto-cancel target of the action being handled.
    let visit: ([Int]) -> Void
    let sendAction: (Action) throws(CancellationError) -> Task<Void, Never>?
    let modifyState: ((inout State) -> Void) throws(CancellationError) -> Void
    let lastKnown: LastKnown<State>

    /// The committed state. Read from effects; during `interact` it is the pre-action value and the
    /// read is reported (use the `inout` argument instead). After the model is gone, or a
    /// case-scoped child is no longer active, it is the last known value and the read is reported.
    /// Get-only: changes go through ``modify(_:)``.
    public var state: State {
        if isRoutingAction() {
            reportIssue("Read 'effects.state' during interact; use the 'state' argument instead")
        }
        guard let state = readState() else {
            reportIssue("Read 'effects.state' after the model was invalidated or the scoped state went away")
            return lastKnown.value
        }
        lastKnown.value = state
        return state
    }

    /// Enqueues an effect. It starts after `interact` returns, in `perform` order, runs its
    /// synchronous preamble before `send` returns and resumes on the model's isolation after every
    /// suspension. Without an `id`, the effect is auto-cancelled the next time this action case is
    /// handled; with an `id` (``EffectID``), it replaces the previous effect of that key and is
    /// cancelled only through ``cancel(_:)``.
    @available(*, noasync)
    public func perform(id: EffectID.Key? = nil, _ operation: @escaping EffectOperation) {
        enqueue(path, scopePath, id, operation)
    }

    /// Commits a state change from an effect: one commit, one observation pass, one test entry,
    /// however many members `body` touches. This is how an effect delivers its result. Throws only if
    /// the model has been invalidated (deinit); a cancelled effect's change is still committed. During
    /// `interact`, inside another `modify`, or after a case-scoped child's case went away, the change
    /// is reported and dropped. `perform`/`send` inside `body` are reported and dropped.
    public func modify(_ body: (inout State) -> Void) throws(CancellationError) {
        try modifyState(body)
    }

    /// Sends an action back into the feature from an effect, for what a mutation cannot do: start
    /// new effects, run interactor logic, or auto-cancel by action case. Processed synchronously,
    /// depth-first, and returns the task for the effects that action started. Throws only if the
    /// model has been invalidated; a cancelled effect's send is still delivered.
    @discardableResult
    public func send(_ action: Action) throws(CancellationError) -> Task<Void, Never>? {
        try sendAction(action)
    }

    /// Cancels the effect of `id` in this handle's scope. During `interact`: enqueued and executed
    /// in order in the start phase, before the effects queued after it start. From an effect:
    /// immediate.
    public func cancel(_ id: EffectID.Key) {
        enqueueCancel(scopePath, id)
    }

    /// Synchronous. `true` from the effect's start until its operation returns, it is replaced, or
    /// it is cancelled by ``cancel(_:)`` or teardown (an identified effect is never auto-cancelled).
    /// A cancel queued in the same `interact` is not reflected until the start phase. Cancelling
    /// the task returned by `send` cancels the effect too, but `isRunning` reflects that only once
    /// the effect unwinds: the task's cancellation handler runs off the model's isolation and cannot
    /// mark the effect cancelled.
    /// Not observable: a view that needs it reads explicit state the interactor sets and the effect
    /// clears (in a `defer`, because a cancelled effect never reaches the statements after its
    /// suspension point).
    public func isRunning(_ id: EffectID.Key) -> Bool {
        isRunningKey(scopePath, id)
    }
}

/// The value `effects.state` falls back to when the committed state cannot be read. Seeded when the
/// handle is created and refreshed on each successful read; shared by every copy of the handle.
final class LastKnown<State> {
    var value: State

    init(_ value: State) {
        self.value = value
    }
}

extension Effects where State: FeatureState {
    /// The root handle of one `send`.
    init(core: Core<State, Action>, path: [Int]) {
        self.init(
            readState: { [weak core] in core?.committedState },
            isRoutingAction: { [weak core] in core?.isRoutingAction ?? false },
            path: path,
            scopePath: [],
            enqueue: { [weak core] path, scopePath, id, operation in
                guard let core else {
                    reportIssue("'effects.perform' must be called during interact; dropped")
                    return
                }
                core.enqueue(path: path, scopePath: scopePath, id: id, operation)
            },
            enqueueCancel: { [weak core] scopePath, id in core?.cancel(scopePath: scopePath, id: id) },
            isRunningKey: { [weak core] scopePath, id in core?.isRunning(scopePath: scopePath, id: id) ?? false },
            visit: { [weak core] path in core?.visit(path: path) },
            sendAction: { [weak core] action throws(CancellationError) in
                guard let core, !core.isInvalidated else {
                    if !Task.isCancelled { reportIssue("Effect sent \(action) after the model was invalidated") }
                    throw CancellationError()
                }
                return core.send(action)
            },
            modifyState: { [weak core] body throws(CancellationError) in
                guard let core, !core.isInvalidated else {
                    if !Task.isCancelled { reportIssue("Effect modified state after the model was invalidated") }
                    throw CancellationError()
                }
                core.modify(body)  // reports and drops during interact and inside another modify
            },
            lastKnown: LastKnown(core.committedState)
        )
    }
}

extension Effects {
    /// The handle of a child scoped by `When`.
    ///
    /// `initialState` is the child state `When` routes the action to; it seeds the child's last
    /// known value. `extract` returning `nil` means the child is no longer active: its effects'
    /// sends and modifications are reported and dropped. Key-path scoping passes a non-optional
    /// `extract`. `embedState` writes the child back into the parent (key path assignment or case
    /// re-embedding); a child `modify` is one parent commit, so nested `When`s chain upward.
    /// `scopeEntry` (the `When`'s key path or case key path) extends `scopePath` for identified
    /// effects.
    func scope<ChildState, ChildAction>(
        initialState: ChildState,
        extract: @escaping (State) -> ChildState?,
        embed: @escaping (ChildAction) -> Action,
        embedState: @escaping (inout State, ChildState) -> Void,
        childTag: Int,
        scopeEntry: AnyHashable
    ) -> Effects<ChildState, ChildAction> {
        let childPath = path + [childTag]
        visit(childPath)
        let parent = self
        return Effects<ChildState, ChildAction>(
            readState: { parent.readState().flatMap(extract) },
            isRoutingAction: isRoutingAction,
            path: childPath,
            scopePath: scopePath + [scopeEntry],
            enqueue: enqueue,
            enqueueCancel: enqueueCancel,
            isRunningKey: isRunningKey,
            visit: visit,
            sendAction: { childAction throws(CancellationError) in
                if !parent.isRoutingAction(), let parentState = parent.readState(), extract(parentState) == nil {
                    reportIssue("Child effect sent \(childAction) after its state was removed from the parent; dropped")
                    return nil
                }
                return try parent.sendAction(embed(childAction))
            },
            modifyState: { body throws(CancellationError) in
                if !parent.isRoutingAction(), let parentState = parent.readState(), extract(parentState) == nil {
                    reportIssue("Child effect modified state after its state was removed from the parent; dropped")
                    return
                }
                try parent.modifyState { parentState in
                    // Synchronous on the model's isolation, so the check above still holds here.
                    guard var childState = extract(parentState) else { return }
                    body(&childState)
                    embedState(&parentState, childState)
                }
            },
            lastKnown: LastKnown(initialState)
        )
    }

    /// The handle with every enqueued operation wrapped by `transform` (`Debounce`).
    func transformingOperations(
        _ transform: @escaping (@escaping EffectOperation) -> EffectOperation
    ) -> Effects {
        let enqueue = self.enqueue
        return Effects(
            readState: readState,
            isRoutingAction: isRoutingAction,
            path: path,
            scopePath: scopePath,
            enqueue: { path, scopePath, id, operation in enqueue(path, scopePath, id, transform(operation)) },
            enqueueCancel: enqueueCancel,
            isRunningKey: isRunningKey,
            visit: visit,
            sendAction: sendAction,
            modifyState: modifyState,
            lastKnown: lastKnown
        )
    }
}
