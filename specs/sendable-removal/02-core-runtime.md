# Plan 02 — Core Runtime

Workstream 2 of the Sendable-removal rework. This is the load-bearing plan: it defines the new
internal engine (`LatticeCore`) that replaces `Sources/Lattice/Internal/Execution/*`,
`EffectTaskRegistry`, `EffectCancellationRegistry`, and `Debouncer`. Plans 3–7 build against the
internal API surface pinned here. Conforms to the shared design contract in `README.md`; any
deviation requires a README update first.

## 1. Overview

The old runtime is an action pipeline: ViewModel drains a `Deque<BufferedAction>`, each action
runs `interact` and returns an `Emission`, `EmissionExecution` spawns `@Sendable` tasks whose
results re-enter as *more actions* (the ping-pong), and two lock-guarded registries mirror task
state so a nonisolated `deinit` can cancel.

The new runtime is a confined imperative core:

- **One class, `LatticeCore<DomainState, Action>`**, owns the domain state, the path-keyed task
  storage, the mutation-phase state machine, and the single commit funnel. It is
  **not `Sendable` and not actor-isolated in the type system** — it is confined by construction
  to `isolation: any Actor` (`MainActor.shared` today, an off-main host later). No generic
  parameter carries a `Sendable` constraint.
- **Effects launch synchronously in-domain** via a port of TCA26's `Task.immediateIfAvailable`
  (`Task.immediate` on OS 26, the `Task.startOnMainActor` silgen shim on iOS 17–25). Non-Sendable
  closures never actually cross an isolation boundary; the two `nonisolated(unsafe)` captures are
  justified inline.
- **All mutations flow through one funnel**: mutate → transition detection (presence-flipped
  `When` nodes cancel their path-prefix bucket) → host commit hook (the host's projection diff,
  installed at `mount` by plan 6; snapshot recording, installed at `mount` by plan 7).
- **The core is a headless engine driven by hosts through one mounting contract.** `ViewModel`
  and `TestViewModel` are peer hosts; because the commit hook fires synchronously inside the
  funnel, tests observe every commit deterministically without polling.
- **No buffering, no drain loop.** With emissions gone, actions can only be sent when the domain
  is idle (host sends and effect-phase `effectState.send`), so the reentrancy story collapses to loud
  preconditions, TCA26-style.
- **No locked registries.** `Effects` handles and effect-completion callbacks hold the core
  weakly; `EventTask` wraps a plain composite task over effect-task handles and never references
  the core. The last strong reference is the host (`ViewModel`). `deinit` therefore has exclusive
  access and can cancel the task storage directly.

Everything in this plan is **additive**: the new files compile alongside the old runtime. The old
files are deleted when plans 4 and 6 flip the last call sites (§7).

## 2. New file layout

```
Sources/Lattice/Internal/Core/
    GraphPath.swift          structural identity (TCA26 _GraphPath port)
    EffectLocation.swift     per-node effect slot identity + TaskKey
    UpdateContext.swift      mutation-phase state machine + pending effect records
    LatticeCore.swift        the core class + EffectTaskEntry
    TaskLaunch.swift         Task.immediateIfAvailable port + [Task].all combinator
    StartOnMainActor.swift   silgen shim for synchronous MainActor task start
```

`Package.swift` and `Lattice.podspec` glob `Sources/Lattice/**` — no manifest changes.

## 3. New types — full source

### 3.1 `GraphPath.swift`

Faithful port of TCA26 `_GraphPath` (Feature.swift:196–240): ordered components plus an
incrementally maintained FNV-1a hash, so hashing is O(1) regardless of tree depth and prefix
checks are a plain component comparison. `public` per the pinned contract; mutators stay
internal (only the tree walk in plan 4 appends).

Path assignment (owned by plan 4, restated here because storage keys depend on it):

- `When` appends its state keypath (struct scope) or case-path identity (enum scope) — both are
  key-path objects, so `append(_: AnyKeyPath)` covers both.
- Builder blocks append the child's positional index via `append(id: index)`.
- `buildEither` appends a branch tag via `append(id:)`.
- `Interact` is a leaf; it appends nothing.
- The root path is `GraphPath()`. The tree is static, so every leaf's path is computed exactly
  once at `ViewModel` init.

```swift
/// Structural identity of a node in the static interactor tree.
///
/// An ordered component list with an incrementally maintained FNV-1a hash, so hashing is O(1)
/// regardless of tree depth. Effect task storage is keyed by `GraphPath`, and transition
/// detection cancels buckets by path prefix, so `starts(with:)` and cheap hashing are the two
/// operations that matter.
public struct GraphPath: Hashable {
    private var components: [Component] = []
    private var _hashValue: UInt32 = 2_166_136_261  // FNV-1a offset basis

    enum Component: Hashable {
        case keyPath(AnyKeyPath)
        case id(AnyHashable)
    }

    public init() {}

    mutating func append(_ keyPath: AnyKeyPath) {
        _hashValue = (_hashValue ^ UInt32(truncatingIfNeeded: keyPath.hashValue)) &* 16_777_619
        components.append(.keyPath(keyPath))
    }

    mutating func append(id: AnyHashable) {
        _hashValue = ((_hashValue ^ 1) ^ UInt32(truncatingIfNeeded: id.hashValue)) &* 16_777_619
        components.append(.id(id))
    }

    func appending(_ keyPath: AnyKeyPath) -> GraphPath {
        var path = self
        path.append(keyPath)
        return path
    }

    func appending(id: AnyHashable) -> GraphPath {
        var path = self
        path.append(id: id)
        return path
    }

    /// True when `self` is `prefix` or a descendant of it. The transition-detection and
    /// remount primitive.
    func starts(with prefix: GraphPath) -> Bool {
        components.starts(with: prefix.components)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs._hashValue == rhs._hashValue && lhs.components == rhs.components
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(_hashValue)
    }
}
```

Note: `GraphPath` is intentionally **not** `Sendable` (`AnyKeyPath`/`AnyHashable` components).
It lives in-domain; the one off-domain touch (core `deinit`) has exclusive access (§3.5).

### 3.2 `EffectLocation.swift`

The `Location` half of the pinned task-storage key `[GraphPath: [Location: Task]]`.

```swift
/// Identifies the effect "slot" within one tree node that owns a task bucket.
///
/// The first `perform` for a `(path, location)` during one update replaces the in-flight
/// bucket; subsequent `perform`s in the same update track alongside.
enum EffectLocation: Hashable {
    /// Auto-replacement slot identified by the source location of the `perform` call.
    case callSite(fileID: String, line: UInt, column: UInt)
    /// Explicit slot owned by an `@EffectID`.
    case id(AnyHashable)
}

/// Full key for one task bucket: which node, which slot.
struct TaskKey: Hashable {
    let path: GraphPath
    let location: EffectLocation
}
```

`Effects.perform` (plan 3) already carries `#fileID`/`#line`/`#column` default arguments; without
an explicit id the slot is the `perform` call site itself — every send that reaches the same
`perform` line replaces the in-flight bucket there, which covers the debounce-style flows, with
zero reflection cost. `.id(...)` wins whenever an `@EffectID` is given. `GraphPath` already
disambiguates identical helper call sites across tree nodes.

### 3.4 `UpdateContext.swift`

```swift
/// The core's mutation-phase state machine.
///
/// Any phase other than `idle` means a mutation body has exclusive `inout` access to the
/// state, so re-entrant `send`/`modify`/state reads pattern-match the phase and fail with a
/// loud, named precondition instead of Swift's opaque dynamic-exclusivity crash. Type-level
/// phase separation (the update-phase handle exposes only `perform`; the effect-phase handle
/// exposes only `modify`/`send`/`state`) is the first line of defense; these runtime checks
/// are the backstop for handles smuggled across phases and for exclusivity violations.
///
/// Phase discipline (enforced by loud runtime preconditions):
/// - `launchEffect` (backing `perform`) is legal only in `.updating`.
/// - `modify` / `send` / `currentState` are legal only in `.idle`.
enum Phase {
    /// No mutation in progress.
    case idle
    /// `interact` is running for one action — the update phase.
    case updating(UpdateContext)
    /// A `modify` closure is running.
    case modifying
}

/// Present on the core exactly while `interact` runs for one action — the update phase.
struct UpdateContext {
    /// Effects registered by `perform`, launched after the commit funnel runs so their
    /// synchronous prefixes observe committed state and may legally call `modify`/`send`.
    /// Recorded in `perform` order; the launch loop derives replace-vs-track per key from
    /// that order.
    var pendingEffects: [PendingEffect] = []
}

/// One `perform` recorded during an update, awaiting launch.
struct PendingEffect {
    let key: TaskKey
    let operation: () async throws -> Void
}
```

### 3.5 `LatticeCore.swift`

The engine. Design notes precede the source:

- **Deferred launch.** `perform` during the update phase only *records* a `PendingEffect`.
  Launch happens after the commit funnel. This is load-bearing: `Task.immediateIfAvailable`
  starts the body synchronously, and the body's synchronous prefix must be allowed to call
  `modify`/`send` (which precondition the idle phase) and must observe committed,
  already-diffed state. TCA26 does the same via its `taskQueue`/`runHooks` split.
- **`EffectTaskEntry` box.** Because tasks start immediately, an effect body can synchronously
  *finish*, or synchronously cancel *its own* bucket (e.g. a `modify` that nils the enum case it
  lives under), before `Task.immediateIfAvailable` has even returned the task handle. The entry
  box is registered in storage *before* launch; `cancel()` before `attach(_:)` marks the entry
  and cancels the task the moment it is attached (cancellation is cooperative, so
  cancel-after-sync-prefix is correct semantics).
- **One `phase` state machine.** The update phase (`.updating`, carrying the pending-effect
  context) and the exclusive `inout` window of a `modify` closure (`.modifying`) are two states
  of a single `phase` value. Exclusive `inout` access to the `state` property exists in both,
  so every re-entrant path that would otherwise trip Swift's dynamic exclusivity enforcement on
  `state` with an opaque crash pattern-matches `phase` and fails with a loud, named
  precondition instead. These checks are a **backstop** now: the typed handles (`Effects` has no
  `modify`/`send`, `EffectState` has no `perform`) make phase separation a compile-time property,
  so the preconditions only fire for a handle smuggled across phases or a genuine exclusivity
  violation (reentrant `modify`).
- **Re-entrant `send`/`modify` after commit is legal.** The funnel runs the host hook with
  value copies (never with `state` `inout`-open), so a synchronous observer that sends is a
  plain recursion, matching TCA26. The old drain-loop deferral is gone; unbounded synchronous
  recursion is an app bug (risk §10).
- **Structured quiescence, no stored continuations.** `send` returns a composite task
  (`[Task].all`, §3.6) over the effect tasks the update launched directly — awaiting it is
  quiescence, cancelling it propagates to every one of those effects. No per-send bookkeeping
  lives on the core; the one deliberately kept box is `EffectTaskEntry`, which exists for the
  immediate-start races (a presence flip can cancel an entry before its task handle is
  attached). Work started by a re-entrant `effectState.send` is an independent unit covered by that
  send's own returned task.
- **Lifetime.** Everything that captures the core across a suspension holds it weakly (`Effects`
  in plan 3, effect wrappers here). The host's strong reference is the core's lifetime; `deinit`
  cancels everything with exclusive access. The composite task holds only `Task` handles, never
  the core.

```swift
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
```

### 3.6 `TaskLaunch.swift`

Port of TCA26 `Internal/Task.swift`, trimmed to what Lattice needs: the `Failure == Never`
variant only (effect wrappers catch everything), no task naming (`Task(name:)` availability is
murkier than its worth), plus the small `[Task].all` combinator backing the composite handle
`send` returns.

```swift
extension Task where Failure == Never {
    /// Starts a task synchronously in the caller's isolation domain when the runtime allows:
    /// `Task.immediate` on OS 26+, the `Task.startOnMainActor` shim on iOS 17–25 for the
    /// MainActor, and a plain `Task` otherwise (the operation still *runs* isolated to the
    /// captured context via `@isolated(any)`; only the synchronous start is lost — acceptable
    /// because non-main hosting is an OS 26+ tier where `Task.immediate` exists).
    ///
    /// The synchronous in-domain start is what makes non-`@Sendable` effect operations safe to
    /// launch: the closure is invoked before control returns to the caller, in the same
    /// isolation domain, so captured non-Sendable state never crosses a boundary.
    @discardableResult
    static func immediateIfAvailable(
        priority: TaskPriority? = nil,
        isolation: (any Actor)? = #isolation,
        @_implicitSelfCapture @_inheritActorContext(always)
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            Task.immediate(priority: priority, operation: operation)
        } else if isolation === MainActor.shared {
            MainActor.assumeIsolated {
                Task.startOnMainActor(priority: priority) {
                    await operation()
                }
            }
        } else {
            Task(priority: priority, operation: operation)
        }
    }
}

extension Array where Element == Task<Void, Never> {
    /// Folds many tasks into one: awaiting the result awaits every task; cancelling it
    /// cancels every task. Backs the composite handle `send` returns for the effects an
    /// update launched.
    ///
    /// `Task` handles are `Sendable`, so no unsafe captures are needed here.
    func all() -> Task<Void, Never> {
        let tasks = self
        return Task {
            await withTaskCancellationHandler {
                for task in tasks {
                    await task.value
                }
            } onCancel: {
                for task in tasks {
                    task.cancel()
                }
            }
        }
    }
}
```

### 3.7 `StartOnMainActor.swift`

Verbatim port of TCA26 `Internal/StartOnMainActor.swift`, `Never` variant only. The
`@_silgen_name` binds to the concurrency runtime's internal
`Task.startOnMainActor(priority:_:)` entry point (the forums-documented technique TCA has
shipped in production for years). It starts the closure synchronously on the MainActor —
exactly the pre-OS-26 gap `Task.immediate` closes. OS 26+ never reaches this code path.

```swift
// https://forums.swift.org/t/async-await-is-it-possible-to-start-a-task-on-mainactor-synchronously/52862/23

extension Task where Failure == Never {
    @_silgen_name("$sScTss5NeverORs_rlE16startOnMainActor8priority_ScTyxABGScPSg_xyYaYbScMYccntFZ")
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @discardableResult
    @MainActor
    static func startOnMainActor(
        priority: TaskPriority? = nil,
        @_inheritActorContext @_implicitSelfCapture _ work:
            consuming @Sendable @escaping @MainActor () async -> Success
    ) -> Task<Success, Never>
}
```

## 4. Internal API surface for plans 3–7

This table is the contract. Plans 3–7 may consume exactly this; anything more comes back to
this plan first.

| Member | Phase | Consumer | Purpose |
|---|---|---|---|
| `init(initialState:isolation:)` | — | plan 6/7 hosts | one core per host; `MainActor.shared` today |
| `mount(interact:onCommit:onEffectLaunched:)` | pre-use | plan 6 (wires interact + onCommit projection diff), plan 7 (wires onCommit snapshot recorder + onEffectLaunched) | install the host contract: routing closure plus the host's observation hooks |
| `registerPresenceWatcher(path:isPresent:)` | pre-use | plan 4 tree walk | transition detection inputs |
| `send(_:) throws -> Task<Void, Never>?` | idle | plan 6 `sendViewEvent`, plan 3 `EffectState.send` | route an action; returns a composite task over the directly launched effects (`nil` when none) — `EventTask` wraps it |
| `modify(_:) throws` | effect phase | plan 3 `EffectState.modify` (via pullback) | the mutation re-entry; runs the funnel |
| `currentState` | effect phase | plan 3 `EffectState.state` | committed-state read |
| `updateContext` (read) | any | plan 3 `Effects` | phase check (non-nil ⇔ update phase) |
| `launchEffect(path:location:operation:)` (`noasync`) | update phase | plan 3 `Effects.perform` | record effect; replace-then-track per key |
| `cancelTasks(at:)` / `hasTasks(at:)` / `currentTasks(at:)` | idle | plan 3 `@EffectID` | explicit cancel / isRunning / await |
| `cancelTasks(withPrefix:)` | idle | core funnel, plan 3 pullback drop | subtree cancellation |
| `dismount()` / `isDismounted` | idle | plan 6/7 teardown | explicit teardown; post-dismount `send`/`modify` throw |
| `EffectLocation.callSite(fileID:line:column:)` | — | plan 3 | default `perform` location (from plan 3's `#fileID`/`#line`/`#column`) |
| `GraphPath.appending(_:)` / `appending(id:)` / `GraphPath()` | mount | plan 4 tree walk | path assignment |
| `TaskKey(path:location:)` | — | plan 3 | `@EffectID` key construction |

Host wiring shape (normative for plan 6; shown here because it closes the loop):

```swift
// ViewModel init (MainActor):
let core = LatticeCore<DomainState, Action>(initialState: initialDomainState, isolation: MainActor.shared)
// the tree walk: computes leaf paths, registers presence watchers, returns the route closure
core.mount(
    interact: { [unowned core] state, action in
        root.route(state: &state, action: action, core: core, path: GraphPath())
    },
    onCommit: { [registrar] oldState, newState in
        // the generated projection diff fires the host-owned registrar for changed members;
        // the registrar batch pokes each signal once per commit (plan 05)
        registrar.commit {
            DomainState._commit(old: oldState, new: newState, registrar: registrar, key: ProjectionKey())
        }
    }
)

// sendViewEvent:
return EventTask(rawValue: (try? core.send(event)) ?? nil)
```

## 5. Semantics locked by this plan

- **Funnel order** (every mutation): mutate → presence-flip prefix cancellation → `onCommit`
  (projection diff; the `.sent`-and-equal skip is deleted) → for `send` only: launch
  pending effects and return their composite task.
- **Replace-then-track**: first `perform` at a `(path, location)` in one update cancels the
  existing bucket at launch time; subsequent `perform`s in the same update append. Handling an
  action *without* a `perform` cancels nothing (README specifies replacement on `perform` only;
  TCA26's no-addTask auto-cancel is deliberately not ported).
- **Effect ordering**: effects launch after commit, in `perform` order; each body runs
  synchronously in-domain up to its first suspension, and may synchronously `modify`/`send`
  (each is its own funnel pass) or even cancel itself.
- **EventTask coverage is direct-effects-only**: the task returned from `send` covers exactly
  the effects that send's update launched. Work started via a XX  independent unit with its own returned task — awaiting or cancelling the original send's task
  neither waits for nor cancels it.
- **Dismount/deinit**: cancel everything (composite send tasks complete as their effects wind
  down, so awaiting them never hangs), and poison `send`/`modify` with `CancellationError`.

## 6. Modified existing files

**None.** This workstream is purely additive — the `Internal/Core/` files reference nothing in
`Internal/Execution/` and vice versa, so `swift build` stays green with both runtimes present.
All integration diffs (ViewModel host rewrite, combinator routing, Effects handle) belong to
plans 3–6, which is what keeps each landing reviewable.

## 7. Deletion list

Executed as the *final* step of workstream 6 (ViewModel flip), when the last references die.
Listed here because this core is their replacement:

```
Sources/Lattice/Internal/Execution/ActionSource.swift
Sources/Lattice/Internal/Execution/ActionTransition.swift
Sources/Lattice/Internal/Execution/ApplyAction.swift
Sources/Lattice/Internal/Execution/BufferedAction.swift
Sources/Lattice/Internal/Execution/EffectID.swift
Sources/Lattice/Internal/Execution/EmissionExecution.swift
Sources/Lattice/Internal/Execution/RootScopeState.swift
Sources/Lattice/Internal/Execution/RootScopeTasks.swift
Sources/Lattice/Internal/Execution/SendScopeID.swift
Sources/Lattice/Internal/EffectTaskRegistry.swift
Sources/Lattice/Internal/EffectCancellationRegistry.swift
Sources/Lattice/Internal/Debouncer.swift
Sources/Lattice/Internal/DebounceResult.swift
Sources/Lattice/Internal/Send.swift                       (dead code; per README deletions)
Sources/Lattice/Internal/UncheckedSendable.swift          (dead code; per README deletions)
```

(`Emission.swift`, `Emission+Debounce.swift`, `DebounceToken`, `Interactors.Debounce`,
`DynamicState.swift` are workstream-4 deletions; `TestViewModel`'s pipeline copy is
workstream 7.)

Note the old `EffectID` (UUID per spawned task) is deleted, not ported: task identity inside the
core is `EffectTaskEntry.id`, and the *public* `@EffectID` of plan 3 is a different concept
(a named slot ⇒ `EffectLocation.id`).

## 8. Unit test plan — core in isolation

New directory: `Tests/LatticeTests/InternalTests/CoreTests/` (Swift Testing, `@testable import
Lattice`). The core has no dependency on `Interactor`/`Effects`/`ViewModel`, so these run before
any of plans 3–7 land. Shared fixture: a deliberately **non-Sendable** state
(`struct S { var n = 0; var child: Child?; var box: NonSendableBox }`) to prove the runtime
compiles and runs without any `Sendable` requirement.

`GraphPathTests.swift`
- equality/hash: same appends ⇒ equal & same hash; differing keyPath vs id component ⇒ unequal.
- `starts(with:)`: reflexive; parent prefix of child; sibling positional indices not prefixes of
  each other; empty root path prefixes everything.
- branch tags: `buildEither`-style `append(id:)` distinguishes branches at the same position.

`CoreCommitFunnelTests.swift` (all `@MainActor`)
- `send` runs the mounted closure exactly once with the action; `onCommit` receives correct
  old/new values.
- `onCommit` fires on **every** commit, including a send whose interact does not mutate
  (diff-on-every-commit contract).
- `modify` runs the funnel: state visible via `currentState`, `onCommit` fired, no update phase.
- presence flip: register watcher for `\.child != nil`; launch an effect under the child path;
  a `send` that nils `child` cancels the child bucket (effect observes `Task.isCancelled`);
  sibling buckets untouched.
- presence flip via `modify` cancels identically (funnel shared by both entry points).
- prefix semantics: cancelling `parent` path cancels `parent/child` buckets but not a positional
  sibling.

`CoreEffectLaunchTests.swift`
- deferred launch ordering: effect body's synchronous prefix observes the committed `onCommit`
  call (record order into an array: `[interact, commit, effectPrefix]`).
- synchronous in-domain start: effect prefix runs before `send` returns and
  `MainActor.assertIsolated()` succeeds inside it (iOS 17–25 path via `startOnMainActor`).
- replace-then-track: send A launches long-running effect from a `perform` call site; send A
  again reaching the same `perform` line ⇒ first task cancelled, new one tracked; two `perform`s
  in one update at the same call site ⇒ both alive.
- same call site ⇒ same slot: repeated sends reaching one `perform` line replace the in-flight
  bucket (replacement observed).
- two different `perform` call sites in one update ⇒ distinct slots coexist (no replacement).
- explicit id vs call site: `.id("x")` and a `.callSite` slot coexist.
- self-cancel race: effect synchronously `modify`s state to flip its own presence watcher ⇒
  its entry is cancelled via `wasCancelledEarly`, body observes cancellation at next await.
- synchronous completion: effect with no suspension ⇒ storage empty after `send`; the returned
  composite task is non-nil and completes immediately when awaited.
- error path: throwing effect (non-cancellation) completes bookkeeping (bucket removed, the
  returned composite task completes); with `IssueReportingTestSupport`, `withExpectedIssue`
  asserts the report.

`CoreSendTaskTests.swift`
- no effects ⇒ `send` returns `nil`.
- `finish` semantics: the returned composite task completes only after every effect the send
  launched completes.
- direct-only coverage: an effect re-enters via `send` and that update launches a second
  effect; the original send's task completes without awaiting the second effect, and the
  re-entrant `send` returns its own task covering it.
- cancel: cancelling the returned composite task cancels the send's in-flight effect tasks;
  the composite completes once they wind down.
- two concurrent sends' returned tasks stay independent.

`CoreDismountTests.swift`
- `dismount()` cancels all tasks; `modify`/`send` after ⇒ `CancellationError`; outstanding
  composite send tasks complete (no hang).
- idempotent dismount.
- `deinit`: release the core while an effect is suspended; effect observes cancellation; its
  completion callback no-ops through the dead weak reference (no crash, verified under TSan in
  the gate below).

`CorePhaseDisciplineTests.swift` (exit tests, `#expect(processExitsWith: .failure)`, gated
`#if os(macOS)` — Swift Testing exit tests require the 6.2 toolchain from plan 1)
- `modify` during update phase traps with the documented message.
- `send` during update phase traps.
- reentrant `modify` inside a `modify` closure traps.
- `currentState` read during update phase traps (instead of an opaque exclusivity crash).
- `launchEffect` outside the update phase traps.

These exit tests exercise the core directly, below the typed handles, so they stay reachable.
The public API makes them unreachable without smuggling a handle across phases: the typed
handles (`Effects` exposes only `perform`; `EffectState` only `modify`/`send`/`state`) give
compile-time phase separation, and plan 3's tests own the compile-time negatives.

## 9. Acceptance gates

1. `swift build` — green with the six new files added and zero existing files touched.
2. `swift test --filter CoreTests` — all of §8 green.
3. `swift test` — full suite still green (old runtime untouched).
4. Concurrency hygiene grep over `Sources/Lattice/Internal/Core/`:
   - zero `@unchecked Sendable`, zero `Sendable` constraints on generics;
   - every `nonisolated(unsafe)` (expected: 3 sites — `operation`, `weakSelf`, `key`)
     carries a `// Safe:` justification.
5. `CoreEffectLaunchTests` + `CoreDismountTests` pass under
   `swift test --filter CoreTests --sanitize=thread` (validates the deinit/weak-capture
   confinement argument).
6. Plans 3–7 consume only the §4 surface (checked at their reviews against this table).
7. Deletion list (§7) executes at end of workstream 6 with `swift test` green and zero
   remaining references (`grep -rn "EmissionExecution\|EffectTaskRegistry\|EffectCancellationRegistry\|RootScope\|BufferedAction\|Debouncer" Sources/` empty).

## 10. Risks

- **`@_silgen_name` shim** binds an internal concurrency-runtime symbol. Mitigation: identical
  to what TCA has shipped for years; only exercised on iOS 17–25 MainActor hosts; OS 26+ uses
  the official `Task.immediate`. If a future runtime drops the symbol, the fallback is a plain
  `Task { @MainActor in }` (losing only the synchronous start — a behavior change, not a
  soundness hole, because captures would then need revisiting; tracked as a toolchain-watch
  item in plan 1).
- **Immediate-start races** (sync completion, self-cancellation before attach) are the
  subtlest logic here; covered by dedicated tests (§8) and the `EffectTaskEntry` box design.
- **Call-site effect-slot identity**: edits that move line numbers change slot identity between
  builds (harmless — worst case one stale task overlaps until completion); a `perform` inside a
  shared helper collapses to one slot per tree node (documented; `@EffectID` is the escape hatch).
- **Synchronous re-entrant `send` from `onCommit` observers can recurse unboundedly.** The old
  drain loop deferred these; the new core allows recursion like TCA26. The funnel runs the
  host hook with value copies, so recursion is safe but unbounded; plan 6 must re-cover the
  reentrancy suite (`ViewModelReentrancyTests`) against the new host.
- **EventTask behavioral deltas**: quiescence is a structured await on the send's composite
  task instead of 1 ms-polled (strictly better, but timing-sensitive tests in plans 6–7 may
  need adjustment); coverage is direct-effects-only — work started by a re-entrant
  `effectState.send` is a separate unit (approved semantics change; plans 3/6 document it); effects
  that complete synchronously still yield a non-nil task, so `hasEffects == true` with an
  immediate `finish()` (worth an explicit ViewModel test in plan 6).
- **Deinit confinement argument** relies on *every* long-lived strong reference to the core
  living in-domain (host) with all cross-suspension captures weak. Plan 3's `Effects` must keep
  its core reference weak — called out in its review checklist; gate §9.5 (TSan) backs it.
- **Non-main hosts on iOS < 26** lose the synchronous-start guarantee (plain `Task` fallback).
  Not reachable today (ViewModel pins `MainActor.shared`); the off-main tier is OS 26-gated per
  README, where `Task.immediate` restores the guarantee.

## 11. Future dynamic-body remount — seams (explicit)

No remount machinery is built now (decision of record). The substrate it lands on later:

1. **Task storage is path-keyed with prefix cancellation** (`tasks: [GraphPath: ...]`,
   `cancelTasks(withPrefix:)`): remounting a subtree is "cancel prefix, keep siblings" — no
   re-keying, because positional indices and keypath components of untouched siblings are
   stable in a static prefix.
2. **`mount(interact:)` stores a swappable `var`** behind the single `send` funnel: remount is
   a closure swap plus a prefix cancel.
3. **`presenceWatchers` carry their `GraphPath`**: a remount deregisters by
   `watchers.removeAll { $0.path.starts(with: prefix) }` and re-registers the new subtree —
   the registration API needs no change.
4. **`runCommitFunnel` is the only post-mutation choke point**: dynamic-body re-evaluation
   hooks (TCA26's `postProcessingHooks`) slot in as an additional hook list there without
   touching `send`/`modify` call sites.
