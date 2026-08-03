import Foundation

#if canImport(IssueReporting)
    import IssueReporting
#endif

/// The runtime engine behind one mounted feature tree.
///
/// One `LatticeCore` exists per `ViewModel` and per `TestViewModel`. It owns:
/// - the domain state,
/// - the path-keyed effect task storage `[GraphPath: [EffectLocation: [task]]]`,
/// - the mutation-phase state machine (`phase`),
/// - the single commit funnel every mutation flows through.
///
/// ## Confinement
///
/// `LatticeCore` is deliberately **not** `Sendable` and not actor-isolated in the type system.
/// It is confined by construction: every member except `deinit` must be called from
/// `isolation`'s domain (`MainActor.shared` for the standard host; an off-main host passes a
/// different actor, OS 26+). Effects capture the core weakly and only touch it from
/// tasks started in-domain via `Task.immediateIfAvailable`.
final class LatticeCore<DomainState, Action> {

    // MARK: - Isolation & lifecycle

    /// The isolation domain this core is confined to. Carried as a value — not a type-level
    /// annotation — so an off-main host can supply a different actor without re-typing the
    /// runtime.
    let isolation: any Actor

    private(set) var isDismounted = false

    // MARK: - State

    private var state: DomainState

    // MARK: - Routing

    /// Runs the interactor tree for one action. Installed once by the host via
    /// `mount(interact:)`.
    ///
    /// Remount seam: this is a `var` behind a single funnel (`send`). A future dynamic-body
    /// runtime swaps the closure on remount; task storage is path-keyed so surviving siblings
    /// keep their buckets untouched.
    private var interact: ((inout DomainState, Action) -> Void)?

    /// Post-mutation host hook — installed at mount by the host to diff the view projection and
    /// notify observers in production, the snapshot recorder in tests. Runs on **every** commit,
    /// after transition detection. Receives value copies; `state` is never `inout`-open while it
    /// runs.
    ///
    /// Remount seam: if dynamic-body re-evaluation ever needs more hooks, this becomes an
    /// array; `runCommitFunnel` is the only call site.
    private var onCommit: ((_ oldState: DomainState, _ newState: DomainState) -> Void)?

    /// Host hook observing each launched effect task at its storage key. The standard host does
    /// not install it; the test host (a peer host) uses it for deterministic effect-start
    /// observation.
    private var onEffectLaunched: ((TaskKey, Task<Void, Never>) -> Void)?

    // MARK: - Phase discipline

    /// The mutation-phase state machine. See `Phase`.
    private var phase: Phase = .idle

    /// The context of the in-progress update — non-nil exactly while `interact` runs for one
    /// action. The effects handle reads it for its phase checks.
    var updateContext: UpdateContext? {
        if case .updating(let context) = phase { return context }
        return nil
    }

    // MARK: - Task storage

    /// Path-keyed effect task storage — the substrate transition detection, `@EffectID`, and
    /// future dynamic-body remount all operate on.
    private var tasks: [GraphPath: [EffectLocation: [EffectTaskEntry]]] = [:]

    /// Scoped (`When`) nodes whose state presence can flip (case-path / optional scopes).
    /// Registered once at mount by the tree walk; evaluated on every commit.
    private var presenceWatchers: [PresenceWatcher] = []

    struct PresenceWatcher {
        let path: GraphPath
        let isPresent: (DomainState) -> Bool
    }

    // MARK: - Init / mount

    init(initialState: DomainState, isolation: any Actor) {
        self.state = initialState
        self.isolation = isolation
    }

    /// Installs the host contract: the routing closure that runs the interactor tree for one
    /// action, plus the host's observation hooks. Called once by the host after building the
    /// static tree.
    ///
    /// - Parameters:
    ///   - interact: routes one action through the tree.
    ///   - onCommit: post-mutation host hook; runs on every commit after transition detection,
    ///     receiving value copies. `nil` for hosts that observe nothing.
    ///   - onEffectLaunched: observes each launched effect task at its storage key. The standard
    ///     host does not install it; the test host (a peer host) does.
    func mount(
        interact: @escaping (inout DomainState, Action) -> Void,
        onCommit: ((_ oldState: DomainState, _ newState: DomainState) -> Void)? = nil,
        onEffectLaunched: ((TaskKey, Task<Void, Never>) -> Void)? = nil
    ) {
        precondition(self.interact == nil, "Feature tree is already mounted.")
        self.interact = interact
        self.onCommit = onCommit
        self.onEffectLaunched = onEffectLaunched
    }

    /// Registers a scoped node whose state presence can flip (enum case / optional). Key-path
    /// scopes are always present and must not register.
    func registerPresenceWatcher(path: GraphPath, isPresent: @escaping (DomainState) -> Bool) {
        presenceWatchers.append(PresenceWatcher(path: path, isPresent: isPresent))
    }

    // MARK: - Entry points

    /// Routes one action through the interactor tree, runs the commit funnel, then launches
    /// the effects recorded during the update.
    ///
    /// - Returns: a composite task over the effects this send launched directly — awaiting it
    ///   awaits them all, cancelling it cancels them — or `nil` when the update launched no
    ///   effects. Work started later by a re-entrant `effectState.send` belongs to that send's own
    ///   returned task.
    /// - Throws: `CancellationError` if the core is dismounted.
    @discardableResult
    func send(_ action: Action) throws -> Task<Void, Never>? {
        guard !isDismounted else { throw CancellationError() }
        switch phase {
        case .idle:
            break
        case .updating:
            preconditionFailure(
                """
                Can't send an action from inside 'interact'; mutate the 'inout' state directly, \
                or launch an effect via 'perform' and re-enter with 'send' on the effect handle \
                passed to 'perform' from there.
                """
            )
        case .modifying:
            preconditionFailure(
                "Can't send an action from inside a 'modify' closure; mutate the 'inout' state instead."
            )
        }
        guard let interact else {
            preconditionFailure("Sent an action to a core with no mounted feature tree.")
        }

        let oldState = state
        phase = .updating(UpdateContext())
        interact(&state, action)
        var pending: [PendingEffect] = []
        if case .updating(let context) = phase {
            pending = context.pendingEffects
        }
        phase = .idle

        runCommitFunnel(oldState: oldState, newState: state)
        return launch(pending)
    }

    /// Re-entry point for effects: mutates state and runs the commit funnel. No effects can
    /// launch from here — `perform` is update-phase only.
    ///
    /// - Throws: `CancellationError` if the core is dismounted. (The `EffectState` handle maps a
    ///   dead weak core reference to the same error.)
    func modify(_ mutate: (inout DomainState) -> Void) throws {
        guard !isDismounted else { throw CancellationError() }
        switch phase {
        case .idle:
            break
        case .updating:
            preconditionFailure(
                "Can't call 'modify' during the update phase; mutate the 'inout' state passed to 'interact' instead."
            )
        case .modifying:
            preconditionFailure(
                "Reentrant 'modify'; don't call 'modify' from inside another 'modify' closure."
            )
        }

        let oldState = state
        phase = .modifying
        mutate(&state)
        phase = .idle
        runCommitFunnel(oldState: oldState, newState: state)
    }

    /// Effect-phase state read (`EffectState.state`). Illegal while `state` is `inout`-open —
    /// the running mutation already has exclusive access, and a second read of the property
    /// would trip dynamic exclusivity enforcement. The precondition names the error instead.
    var currentState: DomainState {
        guard case .idle = phase else {
            preconditionFailure(
                "Can't read 'EffectState.state' during the update phase; use the 'inout' state passed to 'interact'."
            )
        }
        return state
    }

    // MARK: - Effect launch (update phase)

    /// Registers an effect for launch at the end of the current update phase. Backs
    /// `Effects.perform`.
    @available(*, noasync)
    func launchEffect(
        path: GraphPath,
        location: EffectLocation,
        operation: @escaping () async throws -> Void
    ) {
        guard case .updating(var context) = phase else {
            preconditionFailure(
                "Tried to launch an effect outside the update phase of a feature; 'perform' is only callable while 'interact' is running."
            )
        }
        context.pendingEffects.append(
            PendingEffect(key: TaskKey(path: path, location: location), operation: operation)
        )
        phase = .updating(context)
    }

    /// Launches the update's recorded effects and returns a composite handle over them.
    ///
    /// Replace-vs-track is derived from `pending`'s order: the first effect at a given key
    /// cancels (replaces) the in-flight bucket at that key; later effects at the same key in
    /// the same batch track alongside.
    private func launch(_ pending: [PendingEffect]) -> Task<Void, Never>? {
        var seenKeys = Set<TaskKey>()
        var launched: [Task<Void, Never>] = []
        launched.reserveCapacity(pending.count)
        for effect in pending {
            if seenKeys.insert(effect.key).inserted {
                cancelTasks(at: effect.key)
            }

            // Register bookkeeping *before* launch: the body starts synchronously and may
            // finish — or cancel its own bucket via 'modify' — before the task handle exists.
            let entry = EffectTaskEntry()
            tasks[effect.key.path, default: [:]][effect.key.location, default: []].append(entry)

            // Safe: the trailing closure of 'immediateIfAvailable' is executed exactly once and
            // starts synchronously in `isolation`'s domain, so the non-Sendable operation never
            // actually crosses an isolation boundary.
            nonisolated(unsafe) let operation = effect.operation
            // Safe: only dereferenced from inside the task body, which runs in-domain.
            weak nonisolated(unsafe) let weakSelf = self
            // Safe: value copy, captured for in-domain bookkeeping only.
            nonisolated(unsafe) let key = effect.key
            let entryID = entry.id

            let task = isolation.assumeIsolated { _ in
                Task.immediateIfAvailable {
                    do {
                        try await operation()
                    } catch is CancellationError {
                        // Expected: task cancellation, or a post-dismount 'modify'/'send'.
                    } catch {
                        #if canImport(IssueReporting)
                            reportIssue(error)
                        #endif
                    }
                    // Resumes in-domain: the task is isolated to `isolation`.
                    weakSelf?.effectDidFinish(entryID: entryID, key: key)
                }
            }
            entry.attach(task)
            launched.append(task)
            onEffectLaunched?(effect.key, task)
        }
        return launched.isEmpty ? nil : launched.all()
    }

    private func effectDidFinish(entryID: UUID, key: TaskKey) {
        if var bucket = tasks[key.path]?[key.location] {
            bucket.removeAll { $0.id == entryID }
            tasks[key.path]?[key.location] = bucket.isEmpty ? nil : bucket
            if tasks[key.path]?.isEmpty == true {
                tasks[key.path] = nil
            }
        }
    }

    // MARK: - Commit funnel

    /// The single funnel every mutation flows through:
    /// mutate → transition detection → projection diff (host hook).
    private func runCommitFunnel(oldState: DomainState, newState: DomainState) {
        for watcher in presenceWatchers
        where watcher.isPresent(oldState) && !watcher.isPresent(newState) {
            cancelTasks(withPrefix: watcher.path)
        }
        onCommit?(oldState, newState)
    }

    // MARK: - Cancellation

    /// Cancels and forgets the bucket at one exact key. Used by auto-replacement and by
    /// `@EffectID.cancel`.
    func cancelTasks(at key: TaskKey) {
        guard let bucket = tasks[key.path]?[key.location] else { return }
        for entry in bucket {
            entry.cancel()
        }
        tasks[key.path]?[key.location] = nil
        if tasks[key.path]?.isEmpty == true {
            tasks[key.path] = nil
        }
    }

    /// Cancels every bucket at or below `prefix` — the transition-detection primitive. Also
    /// used by the scoping pullback when a child's state is gone at `modify` time, and by a
    /// future dynamic-body remount tearing down a subtree.
    func cancelTasks(withPrefix prefix: GraphPath) {
        for path in Array(tasks.keys) where path.starts(with: prefix) {
            guard let buckets = tasks[path] else { continue }
            for bucket in buckets.values {
                for entry in bucket {
                    entry.cancel()
                }
            }
            tasks[path] = nil
        }
    }

    /// Whether any effect task is currently tracked at `key` (`@EffectID.isRunning`).
    func hasTasks(at key: TaskKey) -> Bool {
        !(tasks[key.path]?[key.location]?.isEmpty ?? true)
    }

    /// Snapshot of the tasks at `key`, for `@EffectID`'s explicit await.
    func currentTasks(at key: TaskKey) -> [Task<Void, Never>] {
        tasks[key.path]?[key.location]?.compactMap(\.task) ?? []
    }

    // MARK: - Teardown

    /// Tears the runtime down: cancels every effect (outstanding composite send tasks complete
    /// as those effects wind down, so awaiting them never hangs), releases the tree, and makes
    /// all future `modify`/`send` calls throw `CancellationError`. Idempotent. Hosts call this
    /// on explicit teardown; `deinit` performs the same cancellation for the
    /// released-with-host case.
    func dismount() {
        guard !isDismounted else { return }
        isDismounted = true
        cancelEverything()
        interact = nil
        onCommit = nil
        onEffectLaunched = nil
        presenceWatchers.removeAll()
    }

    private func cancelEverything() {
        for buckets in tasks.values {
            for bucket in buckets.values {
                for entry in bucket {
                    entry.cancel()
                }
            }
        }
        tasks.removeAll()
    }

    deinit {
        // Runs on whichever thread drops the last reference, but with exclusive access:
        // refcount is zero, every effect holds this core weakly, and weak references are
        // already nil once deinit begins — no task can observe this storage concurrently.
        // 'Task.cancel()' is Sendable-safe, so no locking is needed here.
        cancelEverything()
    }
}

/// Reference box for one launched effect task.
///
/// A box rather than the bare `Task` because effects start *immediately*: the body can
/// synchronously finish, or synchronously cancel its own bucket, before
/// `Task.immediateIfAvailable` has returned the handle. The box is registered in storage before
/// launch so both races resolve: cancel-before-attach marks the entry and cancels on attach
/// (cooperative cancellation lands at the body's next suspension point).
final class EffectTaskEntry {
    let id = UUID()
    private(set) var task: Task<Void, Never>?
    private var wasCancelledEarly = false

    func cancel() {
        if let task {
            task.cancel()
        } else {
            wasCancelledEarly = true
        }
    }

    func attach(_ task: Task<Void, Never>) {
        self.task = task
        if wasCancelledEarly {
            task.cancel()
        }
    }
}
