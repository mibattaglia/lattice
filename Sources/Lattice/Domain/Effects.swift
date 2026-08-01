/// The update-phase handle for launching asynchronous effects from an interactor.
///
/// An `Effects` handle is passed to every ``Interactor/interact(state:action:effects:)`` call.
/// During that synchronous *update phase* you mutate the `inout` state directly and launch any
/// asynchronous work with ``perform(id:_:fileID:filePath:line:column:)``. `Effects` exposes
/// **only** `perform`: it has no way to mutate or send, so re-entering the runtime from the
/// update phase is a compile error rather than a runtime trap. Launched operations run in the
/// feature's isolation domain (the main actor when hosted by `ViewModel`) and receive an
/// ``EffectState`` handle, which they use to re-enter by calling ``EffectState/modify(_:fileID:filePath:line:column:)``
/// — there is no requirement to send follow-up actions:
///
/// ```swift
/// case .refreshButtonTapped:
///     state.isLoading = true
///     effects.perform { effectState in
///         let items = try await api.fetchItems()
///         try effectState.modify {
///             $0.isLoading = false
///             $0.items = items
///         }
///     }
/// ```
///
/// ## Streams
///
/// Observe a stream by iterating it inside `perform`, calling `modify` on the `EffectState` handle for
/// each element:
///
/// ```swift
/// case .task:
///     effects.perform { effectState in
///         for await location in locationClient.locations {
///             effectState.location = location
///         }
///     }
/// ```
///
/// ## Cancellation
///
/// Effects are cancelled structurally:
/// - The first `perform` at the same call site replaces (cancels) the previous in-flight
///   task launched from that call site; later `perform`s in the *same* update track alongside it.
/// - An explicit ``EffectID`` gives a named handle: `cancel()`, `try await id()`, `isRunning`.
/// - Leaving a `When` scope (enum case departs, optional becomes `nil`) cancels every task the
///   scope launched, and any late ``EffectState/modify(_:fileID:filePath:line:column:)`` from a
///   straggler is dropped silently. See ``EffectState/modify(_:fileID:filePath:line:column:)``.
/// - Tearing down the hosting `ViewModel` cancels everything and makes `modify`/`send` throw
///   `CancellationError`.
///
/// ## Isolation and CPU-bound work
///
/// Operations are non-`@Sendable` and inherit the feature's isolation domain, so they may freely
/// capture non-Sendable state and dependencies. That also means a tight CPU-bound loop inside
/// `perform` blocks the main actor. Hop off explicitly with a `@concurrent` function that
/// takes `sending` values:
///
/// ```swift
/// @concurrent
/// func makeThumbnail(_ data: sending Data) async -> sending Image { … }
///
/// effects.perform { effectState in
///     let thumbnail = await makeThumbnail(imageData)   // runs off-domain
///     effectState.thumbnail = thumbnail                // re-enters in-domain
/// }
/// ```
///
/// `Effects` is intentionally **not** `Sendable`: it must never leave the feature's isolation
/// domain except inside the operation closures the runtime launches in-domain on its behalf.
public struct Effects<DomainState, Action> {
    /// This node's structural identity; effect task buckets are keyed under it.
    let path: GraphPath

    /// The root core's phase signal: non-nil exactly while `interact` runs for one action,
    /// nil when the domain is idle or the core is gone. Captures the core weakly.
    let _updateContext: () -> UpdateContext?

    /// True once the root core is dismounted or deallocated. Captures the core weakly.
    let _isDismounted: () -> Bool

    /// Records one effect with the root core's `launchEffect(path:location:operation:)`,
    /// keyed under this node's path. Captures the core weakly; a dead core no-ops.
    let _launch: (_ location: EffectLocation, _ operation: @escaping () async throws -> Void) -> Void

    /// The effect-phase handle handed to every operation launched from this node. Built once
    /// at mount alongside this handle, over the same lens chain and weak core reference.
    let effectState: EffectState<DomainState, Action>

    /// Binds an `EffectID`'s storage to the root core and this node's task key on first use.
    let _bindEffectID: (EffectID) -> Void

    /// Launches an asynchronous effect from the update phase.
    ///
    /// Legal **only** while `interact` is executing synchronously (`noasync`). The operation is
    /// queued during the update and started in-domain immediately after the update's mutations
    /// commit, using an immediate task (OS 26) or a main-actor synchronous start shim
    /// (iOS 17–25), so it runs up to its first suspension point before control returns to the
    /// caller of `send`. The operation receives an ``EffectState`` handle — the effect-phase
    /// capabilities (`modify`, `send`, `state`) live there, not on `Effects`.
    ///
    /// The first `perform` for a given location during one update **replaces** (cancels) the
    /// in-flight task previously launched at that location; subsequent `perform` calls in the
    /// same update **track** alongside. The location defaults to this `perform` call's source
    /// location: the `fileID`/`line`/`column` arguments below are load-bearing for slot
    /// identity, not merely for issue reporting. Every send that reaches the same `perform`
    /// line shares one slot; passing an ``EffectID`` gives the launch the id's own slot
    /// instead, so distinct IDs at the
    /// same call site do not replace each other.
    ///
    /// Throwing from `operation` is reported as an issue in DEBUG unless the error is a
    /// `CancellationError` or the task carries an ``EffectID`` (which records the error in
    /// ``EffectID/taskError`` instead).
    ///
    /// - Parameters:
    ///   - id: An optional explicit identity for cancellation and awaiting. See ``EffectID``.
    ///   - operation: The asynchronous work. Non-`@Sendable`; runs in the feature's isolation
    ///     domain and receives an ``EffectState`` handle for re-entry. For CPU-bound work, call out
    ///     to a `@concurrent` function with `sending` values — see the type-level discussion.
    @available(*, noasync)
    public func perform(
        id: EffectID? = nil,
        @_implicitSelfCapture _ operation: @escaping (EffectState<DomainState, Action>) async throws
            -> Void,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) {
        guard !_isDismounted() else {
            if !Task.isCancelled {
                latticeReportIssue(
                    "An 'Effects' handle tried to launch an effect for a dismounted feature",
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            }
            return
        }
        guard _updateContext() != nil else {
            latticeReportIssue(
                """
                An 'Effects' handle tried to launch an effect outside the update phase of an \
                interactor
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }

        // Slot identity: an explicit id wins outright; otherwise the call site is the slot.
        let location: EffectLocation
        var generation: UInt64 = 0
        if let id {
            _bindEffectID(id)
            location = .id(ObjectIdentifier(id.storage))
            generation = id.nextGeneration()
        } else {
            location = .callSite(fileID: "\(fileID)", line: line, column: column)
        }

        // The effect-phase handle the operation re-enters through.
        let effectState = self.effectState
        _launch(location) {
            do {
                try await operation(effectState)
                id?.record(error: nil, generation: generation)
            } catch is CancellationError {
                // Expected outcome, not a failure; clears any previously recorded error.
                id?.record(error: CancellationError(), generation: generation)
            } catch {
                if let id {
                    id.record(error: error, generation: generation)
                } else {
                    latticeReportIssue(
                        "An effect failed: \(error)",
                        fileID: fileID, filePath: filePath, line: line, column: column
                    )
                }
            }
        }
    }
}

/// The effect-phase handle passed to the operation closure of ``Effects/perform(id:_:fileID:filePath:line:column:)``.
///
/// `EffectState` is how a launched effect re-enters the runtime: mutate state with
/// ``modify(_:fileID:filePath:line:column:)``, optionally re-dispatch an action with
/// ``send(_:fileID:filePath:line:column:)``, and read the current state with ``state``. For the
/// common case of writing one field, the dynamic-member subscript below reads as a plain
/// assignment (`effectState.isOnline = true`) and is sugar over a single-assignment `modify`. It
/// carries the same weak core reference and `GraphPath`/pullback plumbing as the ``Effects``
/// handle it came from, focused on the same state/action slice.
///
/// It exposes **no** `perform`: launching further effects belongs to the update phase, so
/// nested launching is a compile error rather than a runtime trap.
///
/// `EffectState` is intentionally **not** `Sendable`: it must never leave the feature's isolation
/// domain, and the runtime only ever hands it to operations it launches in-domain.
@dynamicMemberLookup
public struct EffectState<DomainState, Action> {
    /// This scope's structural identity; drop diagnostics and bucket cancellation key off it.
    let path: GraphPath

    /// The root core's phase signal; used only by the smuggled-handle backstops below.
    /// Captures the core weakly (nil when idle or the core is gone).
    let _updateContext: () -> UpdateContext?

    /// Lens-composed write routed through the root core's `modify` funnel. Owns the
    /// departed-scope drop and the dismount `CancellationError`. Captures the core weakly.
    let _modify:
        (_ mutate: (inout DomainState) -> Void, _ fileID: StaticString, _ line: UInt)
            throws(CancellationError) -> Void

    /// Case-path-embedded dispatch through the root core's `send`. Owns the departed-scope
    /// drop and the dismount `CancellationError`. Captures the core weakly.
    let _send:
        (_ action: Action, _ fileID: StaticString, _ line: UInt)
            throws(CancellationError) -> Task<Void, Never>?

    /// Lens-composed read; falls back to the last successfully read snapshot once the target
    /// is gone. Captures the core weakly.
    let _state: () -> DomainState

    /// Modifies the feature's state from an effect, with exclusive access.
    ///
    /// This is the primary re-entry point for asynchronous work: mutate state directly instead
    /// of sending a follow-up action. Every `modify` runs the full commit funnel — transition
    /// detection and the projection diff — exactly like a mutation made during `interact`.
    ///
    /// ## Scope departure
    ///
    /// If this handle is scoped through a `When` whose enum case has been left (or whose
    /// optional is `nil`) by the time `modify` runs, **the mutation is dropped silently** and
    /// the scope's tasks are cancelled. This is the deliberate contract for
    /// navigation-dismissed-mid-request: a late response for a dismissed screen writes nowhere
    /// and does not crash. In DEBUG builds the drop is logged (see `_EffectsDiagnostics`).
    ///
    /// - Throws: `CancellationError` if the feature has been dismounted (host torn down).
    /// - Parameter mutate: A closure given exclusive mutable access to the state.
    public func modify(
        _ mutate: (inout DomainState) -> Void,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) throws(CancellationError) {
        // Backstop: reachable only if this handle was smuggled into the update phase; type
        // separation makes the ordinary path impossible.
        precondition(
            _updateContext() == nil,
            """
            Can't modify state synchronously from an interactor's update phase; mutate the \
            'inout DomainState' passed to 'interact' instead, or enqueue the modification \
            asynchronously via 'effects.perform { effectState in try effectState.modify { … } }'
            """,
            file: fileID,
            line: line
        )
        try _modify(mutate, fileID, line)
    }

    /// Sends an action back into the feature tree from an effect.
    ///
    /// Re-entry via actions is **optional, never required** — prefer
    /// ``modify(_:fileID:filePath:line:column:)`` for plain state writes. Use `send` when the
    /// re-entry should run interactor logic (e.g. a child wants its parent's handlers to see an
    /// event). On a `When`-scoped handle the action is embedded into the parent's action space
    /// and dispatched at the root, so the whole tree routes it.
    ///
    /// The re-entered update is its own unit of work: the returned task covers the effects
    /// that update launched directly, and that work is *not* covered by the ``EventTask`` of
    /// the `sendViewEvent` that started the calling effect. Await the returned task to chain
    /// on the downstream work; discard it to fire and forget.
    ///
    /// If this handle's `When` scope has departed (case left / optional nil'd), the send is
    /// dropped silently and returns `nil`, mirroring ``modify(_:fileID:filePath:line:column:)``.
    ///
    /// - Throws: `CancellationError` if the feature has been dismounted.
    /// - Parameter action: The action to dispatch.
    /// - Returns: A composite task over the effects the re-entered update launched directly,
    ///   or `nil` when it launched none (or the send was dropped).
    @discardableResult
    public func send(
        _ action: Action,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) throws(CancellationError) -> Task<Void, Never>? {
        // Backstop: reachable only if this handle was smuggled into the update phase.
        precondition(
            _updateContext() == nil,
            """
            Can't send an action synchronously from an interactor's update phase; if you need \
            to re-enter with an action, enqueue it asynchronously via \
            'effects.perform { effectState in try effectState.send(action) }'
            """,
            file: fileID,
            line: line
        )
        return try _send(action, fileID, line)
    }

    /// The current state of this handle's scope.
    ///
    /// Read this from effects to observe state that changed since the effect launched.
    ///
    /// While the core is alive the read is live — even after dismount, which cancels work but
    /// does not destroy state (that access is reported as an issue unless the surrounding task
    /// is already cancelled, the normal teardown race). Once the core is deallocated, or this
    /// handle's `When` scope has departed, returns the last state this handle successfully
    /// read. Reading during the update phase is a smuggled-handle error and trips the core's
    /// named state-read precondition — use the `inout` state passed to `interact` instead.
    public var state: DomainState {
        _state()
    }

    /// Reads and writes one field of the domain state as a plain assignment.
    ///
    /// `effectState.x = v` is sugar for `try? modify { $0.x = v }`: the write runs the full
    /// commit funnel exactly once — mutate, transition detection, projection diff — the same
    /// pass `modify` runs for a single assignment. Making several assignments this way commits
    /// each one separately; reach for ``modify(_:fileID:filePath:line:column:)`` when multiple
    /// fields must change together in one commit.
    ///
    /// The subscript cannot throw: unlike `modify`, a write dropped by scope departure or
    /// dismount is silently discarded rather than surfaced, consistent with the pinned
    /// departed-scope drop semantics above. Code that needs to observe cancellation (or a
    /// dismount `CancellationError`) should call `modify` directly.
    ///
    /// The read side routes through the same committed-state read as ``state`` — the
    /// in-update-phase trap on `state` applies here too.
    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<DomainState, Value>) -> Value {
        get { state[keyPath: keyPath] }
        nonmutating set { try? modify { $0[keyPath: keyPath] = newValue } }
    }
}

#if DEBUG
    #if canImport(os)
        import os
    #endif

    enum _EffectsDiagnostics {
        /// Test hook: invoked for every dropped re-entry. Installed by the test host.
        nonisolated(unsafe) static var onDroppedReentry:
            ((_ kind: DroppedReentryKind, _ path: GraphPath, _ fileID: StaticString, _ line: UInt)
                -> Void)?

        enum DroppedReentryKind: String {
            case modify, send
        }

        static func droppedReentry(
            _ kind: DroppedReentryKind,
            path: GraphPath,
            fileID: StaticString,
            line: UInt
        ) {
            onDroppedReentry?(kind, path, fileID, line)
            #if canImport(os)
                logger.debug(
                    """
                    Dropped '\(kind.rawValue)' from an effect at \(String(describing: path)): \
                    the parent's state left this scope's case (or the optional became nil). \
                    The scope's tasks have been cancelled. (\(fileID):\(line))
                    """
                )
            #endif
        }

        #if canImport(os)
            static let logger = Logger(subsystem: "swift-lattice", category: "Effects")
        #endif
    }
#endif
