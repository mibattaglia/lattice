# 03 — Effects Handles: `Effects<DomainState, Action>`, `EffectState<DomainState, Action>`, `EffectID`, Cancellation, Scoping

Workstream 3 of the Sendable-removal rework. Depends on plan `02-core-runtime.md` (the concrete
`LatticeCore` class, `GraphPath`, path-keyed task storage, commit funnel,
`Task.immediateIfAvailable`); plan 02 lands first, so this plan builds against compiled code —
see §"Consumed plan-02 surface". Feeds plan `04-interactor-combinators.md` (which threads the
handle through `When`/`Merge`) and
plan `07-testing.md` (which observes launches/drops through the same internal seams).

Reference model: TCA26 `FeatureStore` (`FeatureDynamicProperties/FeatureStore.swift`) and
`StoreTaskID` (`StoreTaskID.swift`). This plan deliberately mirrors their shape and their
failure-message wording, renamed into Lattice vocabulary. The public API surface is exactly the
pinned contract in `README.md` — no additions beyond defaulted source-location parameters, which
do not change any pinned call shape.

## Overview

`Effects<DomainState, Action>` replaces `Emission<Action>` wholesale. Instead of *returning* a
description of async work, `interact` *receives a handle* and imperatively launches tasks with it
during the synchronous update phase. Phase legality is expressed by **type**, split across two
handles:

- **`Effects<DomainState, Action>`** — the *update-phase* handle passed to `interact`. It exposes
  **only** `perform`. There is no way to mutate or send from it, so cross-phase misuse fails to
  compile rather than trapping at runtime.
- **`EffectState<DomainState, Action>`** — the *effect-phase* handle passed as the parameter of the
  `perform` operation closure. It exposes `modify`, `send`, `state`, and a writable
  dynamic-member subscript for one-line field updates. Launched tasks re-enter
  the runtime by mutating state directly (`modify`, or the subscript sugar for a single field),
  optionally by sending an action (`send`),
  and by reading current state (`state`).

Both handles are bundles of closures built once at mount: each closure composes the scope's
lens chain and captures the root `LatticeCore` weakly, so a `When`-scoped child receives
handles already focused on its state/action slice without ever naming the root feature's type
parameters. There is no observe primitive, no merge, no map: streams are `for await` loops
inside `perform`, composition
is just multiple `perform` calls, and pullback is done by the handles themselves.

Phase legality is a **type** property first, a runtime backstop second:

| Capability | Update-phase handle `Effects` | Effect-phase handle `EffectState` |
|---|---|---|
| `perform` | ✅ (only legal here; `noasync`) | — (not a member) |
| `modify` | — (not a member) | ✅ |
| `send` | — (not a member) | ✅ |
| `state` | — (not a member; read the `inout` state) | ✅ |
| dynamic-member subscript | — (not a member) | ✅ (sugar over `modify`/`state`) |

Because the members live on different types, calling `modify`/`send` from `interact` or `perform`
from an effect is a compile error. The core still keeps loud runtime preconditions (see plan 02)
as a **backstop** for the two cases type separation cannot catch: a handle smuggled across phases
(e.g. captured out of its closure) and genuine exclusivity violations (a reentrant `modify`),
where a named trap replaces Swift's opaque dynamic-exclusivity crash.

Cancellation is structural, three layers (mirrors TCA26 exactly):

1. **Call-site auto-replacement** — the first `perform` for a given `(GraphPath, Location)`
   during one update cancels-and-replaces the in-flight task there; subsequent `perform`s in the
   same update track alongside. `Location` defaults to the source location of the `perform` call
   itself (`#fileID`/`#line`/`#column`).
2. **Explicit `EffectID`** — `@EffectID var refresh`; `refresh.cancel()`, `try await refresh()`,
   `refresh.isRunning`, `refresh.taskError`.
3. **Lifecycle** — a `When` node whose state presence flips (enum case left / optional nil'd)
   has its path-prefix task bucket cancelled by the commit funnel (plan 02); ViewModel deinit
   cancels everything.

Non-goals (explicitly skipped): no `withEffectCancellation` free function (TCA's
`withStoreTaskCancellation` analog — add if consumers need to scope third-party async work to an
`EffectID`), no `name:`/`priority:` parameters on `perform` (add when a profiling need shows up),
no `@Observable` `EffectID` storage (views observe the projection only; add if UI ever needs to bind
`isRunning` directly).

## File layout

| File | Contents |
|---|---|
| `Sources/Lattice/Domain/Effects.swift` | `Effects` (update-phase) + `EffectState` (effect-phase) structs + `_EffectsDiagnostics` DEBUG hooks |
| `Sources/Lattice/Domain/EffectID.swift` | `EffectID` property wrapper + storage |
| `Sources/Lattice/Internal/ScopedEffects.swift` | `_ScopeLens` + `_makeEffectsHandles` (mount-time handle construction; the `When` pullback) |
| `Sources/Lattice/Internal/LatticeIssueReporting.swift` | `latticeReportIssue` shim (IssueReporting when importable, `assertionFailure` fallback for CocoaPods consumers without the dependency) |

`Emission.swift`, `Emission+Debounce.swift` are deleted per README (plan 04 executes the
deletion together with the `interact` signature change).

> Amendment (landed with plan 03): the old runtime's internal `EffectID` struct
> (`Sources/Lattice/Internal/Execution/EffectID.swift`) collided with the new public `EffectID`
> — same module, same name, a redeclaration compile error. It is renamed to `LegacyEffectID`
> (file `Internal/Execution/LegacyEffectID.swift`) with all old-runtime references updated; the
> type is deleted wholesale by the later plans that remove the Emission runtime.

## Production Swift

### `Sources/Lattice/Internal/LatticeIssueReporting.swift`

The existing `reportIssueHelper` lives under `Sources/Lattice/Testing`, which is excluded from
the podspec. Runtime diagnostics need a runtime-safe shim:

```swift
/// Reports a non-fatal runtime misuse.
///
/// Routes through swift-issue-reporting when available (SwiftPM builds, tests) so misuse
/// surfaces as test failures and purple runtime warnings; falls back to `assertionFailure`
/// in DEBUG for integrations without the dependency (e.g. CocoaPods).
func latticeReportIssue(
    _ message: @autoclosure () -> String,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) {
    #if canImport(IssueReporting)
        reportIssue(message(), fileID: fileID, filePath: filePath, line: line, column: column)
    #else
        #if DEBUG
            assertionFailure("\(message()) (\(fileID):\(line))")
        #endif
    #endif
}

#if canImport(IssueReporting)
    import IssueReporting
#endif
```

### `Sources/Lattice/Domain/Effects.swift`

```swift
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
        @_implicitSelfCapture _ operation: @escaping (EffectState<DomainState, Action>) async throws -> Void,
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
```

### Dynamic-member sugar for single-field updates

Most effects change one field. Spelling that as `try effectState.modify { $0.x = v }` is
correct but heavier than the update deserves; the dynamic-member subscript on `EffectState`
lets a single assignment read as a plain assignment, with `modify` staying the tool for
multi-field commits and for code that wants `modify`'s throwing signature:

```swift
effects.perform { $0.isOnline = true }                      // one-liner: single-field update
effects.perform { effectState in                            // named: multi-step work
    let items = try await api.fetchItems()
    try effectState.modify {
        $0.isLoading = false
        $0.items = items
    }
}
```

DEBUG diagnostics for scope-departure drops (fired by the scoped `_modify`/`_send` closures
built in `_makeEffectsHandles` below; the test host in plan 07 installs `onDroppedReentry` to
make drops assertable):

```swift
#if DEBUG
    #if canImport(os)
        import os
    #endif

    enum _EffectsDiagnostics {
        /// Test hook: invoked for every dropped re-entry. Installed by the test host.
        nonisolated(unsafe) static var onDroppedReentry:
            ((_ kind: DroppedReentryKind, _ path: GraphPath, _ fileID: StaticString, _ line: UInt) -> Void)?

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
```

### `Sources/Lattice/Domain/EffectID.swift`

Direct `StoreTaskID` port, minus the dynamic-property mounting (Lattice's tree is static — the
storage class is created when the interactor is initialized and lives as long as the interactor
does) and minus the `@Observable` storage and `completions` table (both existed to serve TCA
features Lattice skips; see non-goals). Unlike TCA26, task bookkeeping does not live here at
all: the identity's tasks are the core's own bucket at
`TaskKey(path: node, location: .id(ObjectIdentifier(storage)))`, and `Storage` holds only
lazily bound routing closures plus error/generation bookkeeping.

```swift
/// A type that identifies an effect launched via ``Effects/perform(id:_:fileID:filePath:line:column:)``.
///
/// Declare one as a property of your interactor and pass it to `perform` to gain an explicit
/// handle on the launched task:
///
/// ```swift
/// struct RecorderInteractor: Interactor {
///     @EffectID var recording
///
///     var body: some InteractorOf<Self> {
///         Interact { state, action, effects in
///             switch action {
///             case .startTapped:
///                 effects.perform(id: recording) { effectState in
///                     for await level in recorder.levels {
///                         try effectState.modify { $0.level = level }
///                     }
///                 }
///             case .stopTapped:
///                 effects.perform { _ in recording.cancel() }
///             }
///         }
///     }
/// }
/// ```
///
/// Because the interactor tree is built once and never remounted, the identity is stable for
/// the lifetime of the feature. The same `EffectID` can be attached to several concurrent tasks;
/// ``isRunning``, ``cancel(fileID:filePath:line:column:)`` and ``callAsFunction()`` cover all of
/// them.
@propertyWrapper
public struct EffectID {
    /// A human-readable name, used in diagnostics. Defaults to `nil`.
    public private(set) var name: String?

    let storage = Storage()

    /// The identity itself; `@EffectID var refresh` reads as `refresh`.
    public var wrappedValue: Self { self }

    /// The error thrown by the most recently completed task attached to this identity, if any.
    ///
    /// `CancellationError` is not recorded — cancellation is an expected outcome, not a
    /// failure. Cleared when a subsequent attached task completes successfully.
    public var taskError: (any Error)? {
        storage.error
    }

    /// Whether any task attached to this identity is currently running.
    ///
    /// Becomes `true` when the effect launches — synchronously, before the `send` that
    /// triggered the update returns — and `false` when the last attached task finishes or is
    /// cancelled. Intended for interactor and effect logic (e.g. "don't start a second
    /// refresh"); views should derive spinners from projected state, not from this flag.
    public var isRunning: Bool {
        storage.hasTasks()
    }

    /// Creates an effect identity.
    ///
    /// - Parameter name: An optional human-readable name used in diagnostics.
    public init(name: String? = nil) {
        self.name = name
    }

    /// Awaits every task currently attached to this identity, then rethrows the recorded
    /// ``taskError`` if one was set.
    ///
    /// ```swift
    /// effects.perform { effectState in
    ///     try await recording()          // wait for the recording effect to finish
    ///     try effectState.modify { $0.phase = .done }
    /// }
    /// ```
    public func callAsFunction() async throws {
        for task in storage.currentTasks() {
            await task.value
        }
        if let error = storage.error {
            throw error
        }
    }

    /// Cancels every task currently attached to this identity.
    ///
    /// Must be called from the effect phase. Calling it synchronously from an interactor's
    /// update phase is reported as an issue and ignored — enqueue it instead:
    /// `effects.perform { _ in refresh.cancel() }`.
    ///
    /// - Returns: One of the cancelled tasks, so callers can await its wind-down; `nil` if
    ///   nothing was running.
    @discardableResult
    public func cancel(
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> Task<Void, Never>? {
        guard !storage.isUpdatePhase() else {
            latticeReportIssue(
                """
                Can't cancel an effect synchronously from an interactor's update phase; if you \
                need to cancel an effect, enqueue the cancellation asynchronously via \
                'effects.perform { _ in \(name ?? "effect").cancel() }'
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return nil
        }
        let tasks = storage.currentTasks()
        storage.cancelledThrough = storage.generation
        storage.cancelTasks()
        return tasks.first
    }

    // MARK: Internal generation machinery (driven by 'Effects.perform')

    /// Claims a fresh generation for one launched operation.
    func nextGeneration() -> UInt64 {
        storage.generation &+= 1
        return storage.generation
    }

    /// Records a launched operation's terminal outcome (`nil` on success; `CancellationError`
    /// recorded as `nil` — cancellation is an expected outcome, not a failure). Ignored when
    /// `cancel()` already retired the generation.
    func record(error: (any Error)?, generation: UInt64) {
        guard generation > storage.cancelledThrough else { return }
        storage.error = error is CancellationError ? nil : error
    }

    final class Storage {
        /// Bound once, by the first `perform(id:)` this identity is passed to. Each closure
        /// captures the root core weakly plus this identity's task key
        /// (`TaskKey(path:location:)` with `.id(ObjectIdentifier(self))`). Unbound — or with
        /// the core gone — the defaults are inert: idle phase, no tasks, cancel is a no-op.
        private(set) var isBound = false
        var isUpdatePhase: () -> Bool = { false }
        var hasTasks: () -> Bool = { false }
        var currentTasks: () -> [Task<Void, Never>] = { [] }
        var cancelTasks: () -> Void = {}

        /// The most recently recorded terminal error. See `record(error:generation:)`.
        var error: (any Error)?
        /// Monotonic launch counter; each launched operation records under its own generation.
        var generation: UInt64 = 0
        /// Generations at or below this were cancelled; their terminal outcome is discarded.
        var cancelledThrough: UInt64 = 0

        func bind(
            isUpdatePhase: @escaping () -> Bool,
            hasTasks: @escaping () -> Bool,
            currentTasks: @escaping () -> [Task<Void, Never>],
            cancelTasks: @escaping () -> Void
        ) {
            self.isUpdatePhase = isUpdatePhase
            self.hasTasks = hasTasks
            self.currentTasks = currentTasks
            self.cancelTasks = cancelTasks
            isBound = true
        }

        deinit {
            cancelTasks()
        }
    }
}
```

Notes:

- Storage closures are bound lazily by the first `perform(id:)` the identity is passed to —
  no mounting step exists or is needed (the same lazy binding TCA26 uses for its store
  reference). Before that, `cancel()`'s phase check passes trivially and there is nothing to
  cancel or await.
- The identity binds to the tree node of its first `perform(id:)` — its declaring interactor.
  Task bookkeeping lives in the core's path-keyed storage under the bound `TaskKey`; because
  the core registers the bucket entry before the task body starts, `isRunning` is `true`
  during the effect's synchronous head start, before the `Task` handle exists.
- `EffectID` is deliberately non-`Sendable` and non-`Equatable`; identity is
  `ObjectIdentifier(storage)`.

### `Sources/Lattice/Internal/ScopedEffects.swift` — handle construction and the `When` pullback

`When` (plan 04) does **not** transform effects values anymore (there are none), and there is
no scoped core object either — Lattice has exactly one runtime core, the root `LatticeCore`
(plan 02). Scoping is **closure erasure**: at mount, each `When` node extends the lens chain it
inherited from its parent (state lens + action case path, alongside the `GraphPath` append it
already does) and builds one `Effects`/`EffectState` pair whose closures compose that chain and
capture the root core **weakly**. The pair is retained by the node's storage (static tree ⇒
built once) and passed to the child's `interact` on every dispatch. The erasure is the whole
trick: `Effects<ChildState, ChildAction>` cannot name the root feature's type parameters, but
closures built at mount — where those parameters are in scope — capture them away.

```swift
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
    // Amendment (landed with plan 03): the '_modify'/'_send' closure literals carry explicit
    // 'throws(CancellationError)' annotations — the compiler does not infer the typed throws
    // from the stored-property contextual type and rejects the bare literals with "invalid
    // conversion of thrown error type 'any Error' to 'CancellationError'".
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
```

Exact drop semantics, spelled out (this is the contract plan 07 tests):

1. **When can a drop happen at all?** Only in the window between the case departing and the
   scope's tasks observing their cancellation. Transition detection in the commit funnel
   (plan 02) cancels the bucket *synchronously* inside the same commit that removed the case, so
   a dropped `modify` only occurs when an effect calls `modify` after being cancelled but before
   hitting a suspension point (e.g. code between `await` and `modify` when the dismissal landed
   during the `await`).
2. **`modify`** — returns normally (does *not* throw; `CancellationError` is reserved for full
   dismount). The closure is never invoked. No commit funnel run, no projection diff.
3. **`send`** — returns `nil` normally; the action is never embedded or dispatched. Rationale: a
   parent handler pattern-matching `.child(.saveResponse)` after the child was dismissed would
   observe re-entry from a scope that no longer exists — the same bug class the `modify` drop
   exists to prevent. (Decision note: the README pins the drop for `modify` only; extending it
   to `send` is this plan's recommendation for consistency — flagged in Risks.)
4. **Task bucket** — `cancelTasks(withPrefix: path)` cancels every task keyed under this
   node's path *and* its descendants (prefix match), then removes them from storage.
5. **`state`** — returns the last successfully read snapshot silently (the effect is already
   cancelled; racing reads during wind-down are expected, mirroring TCA's dismount cache).
6. **DEBUG diagnostics** — `_EffectsDiagnostics.droppedReentry` logs via `os.Logger`
   (subsystem `swift-lattice`, category `Effects`) with the kind, the `GraphPath`, and the call
   site, and invokes the `onDroppedReentry` test hook. Release builds: zero cost, fully silent.

## Cancellation semantics (normative)

Task storage lives in the root core (plan 02): `[GraphPath: [EffectLocation: [EffectTaskEntry]]]`
— per the README, conceptually `[GraphPath: [Location: Task]]` with replace-vs-track folding.

**Location identity** is plan 02's `EffectLocation`. For a plain `perform`, the slot is the
`perform` call site (`.callSite(fileID:line:column:)`, built from `perform`'s own defaulted
`#fileID`/`#line`/`#column` arguments). With an `EffectID`, the slot is
`.id(ObjectIdentifier(id.storage))` — the id wins outright, so two different `EffectID`s
launched from the same call site never replace each other, while re-reaching the same `perform`
line with the same id (or no id) replaces its predecessor. Because
identity is the call site rather than the action, a `perform` inside a shared helper collapses to
one slot per tree node — `@EffectID` is the escape hatch when that is not wanted.

**Replace vs. track.** Per update, derived by the core's launch loop from the recorded effects
in `perform` order (plan 02 §5):

- the *first* `perform` at a given `TaskKey` cancels whatever ran there from a previous
  update (this is the auto-replacement that gives debounce-by-replacement its restart
  semantics);
- every *subsequent* `perform` at the same key in the same update tracks alongside —
  concurrent siblings, no self-cancellation.

**Not adopted (pinned off by plan 02 §5):** TCA26 additionally cancels a
location's tasks when an action handler runs and launches *nothing* there. The README does not
pin that behavior, it changes observable semantics of every no-effect action, and plan 02
deliberately does not port it.

**Lifecycle cancellation.** The commit funnel's transition detection (plan 02) calls
`cancelTasks(withPrefix:)` for every scoped node whose state presence flipped. ViewModel
teardown calls `dismount()` (core `deinit` performs the same cancellation), which cancels every
task and makes later `modify`/`send` throw `CancellationError`.

## Usage examples

### Fetch and modify

```swift
struct SearchInteractor: Interactor {
    let api: SearchAPI   // non-Sendable is fine

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .refreshButtonTapped:
                state.isLoading = true
                effects.perform { effectState in
                    do {
                        let items = try await api.fetchItems()
                        try effectState.modify {
                            $0.isLoading = false
                            $0.items = items
                        }
                    } catch {
                        try effectState.modify {
                            $0.isLoading = false
                            $0.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}
```

### Stream observation (`for await`)

```swift
case .task:
    effects.perform { effectState in
        for await status in networkMonitor.statusUpdates {
            effectState.isOnline = status.isConnected
        }
    }
```

Re-dispatching `.task` replaces the previous subscription (same `perform` call site). Dismissal of
the enclosing `When` scope cancels it.

### Explicit `EffectID`: cancel and await

```swift
struct UploadInteractor: Interactor {
    @EffectID var upload

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .uploadTapped:
                state.phase = .uploading
                effects.perform(id: upload) { effectState in
                    try await api.upload(state.document)
                    effectState.phase = .done
                }

            case .cancelTapped:
                state.phase = .cancelled
                effects.perform { _ in upload.cancel() }

            case .closeTapped:
                effects.perform { effectState in
                    try await upload()                 // wait for in-flight upload, rethrow failure
                    try effectState.send(.readyToClose) // optional action re-entry
                }
            }
        }
    }
}
```

### Debounce by replacement (with `clock.sleep`)

No debounce API — the per-call-site auto-replacement *is* the debounce:

```swift
struct QueryInteractor: Interactor {
    let clock: any Clock<Duration>
    let api: SearchAPI

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .queryChanged(let query):
                state.query = query                    // state mutation is immediate
                effects.perform { effectState in        // previous keystroke's task is cancelled
                    try await clock.sleep(for: .milliseconds(300))
                    let results = try await api.search(query)
                    effectState.results = results
                }
            }
        }
    }
}
```

Each `.queryChanged` dispatch reaches the same `perform` call site, so it is the first `perform`
at that location for its update and replaces the previous one — cancelling the pending `sleep`
and restarting the window. Tests drive this with `TestClock` (survives untouched).

## Consumed plan-02 surface

Plan 02 lands before this plan, so everything below is concrete, compiled code — there is no
seam contract to satisfy, only an internal API to call. This plan consumes exactly these
members of plan 02's §4 table (anything more goes back to plan 02 first):

| Plan 02 member | Used by | For |
|---|---|---|
| `send(_:) throws -> Task<Void, Never>?` | the scoped `_send` closure behind `EffectState.send` | action re-entry; the composite effect task passes through |
| `modify(_:) throws` | the scoped `_modify` closure behind `EffectState.modify` | the single mutation re-entry funnel |
| `currentState` | `EffectState.state`, scope presence pre-checks | committed-state reads |
| `updateContext` (read) | `Effects.perform`, the smuggled-handle backstops, `EffectID.cancel`'s phase check | non-nil ⇔ update phase |
| `launchEffect(path:location:operation:)` (`noasync`) | `Effects.perform` | records the wrapped operation for post-commit launch |
| `cancelTasks(at:)` / `hasTasks(at:)` / `currentTasks(at:)` | `EffectID`'s bound storage closures | explicit cancel / `isRunning` / await |
| `cancelTasks(withPrefix:)` | the scoped `_modify`/`_send` drop paths | idempotent re-cancel of a departed scope's bucket |
| `isDismounted` / `dismount()` semantics | every handle closure | dismount checks; post-dismount `CancellationError` |
| `EffectLocation.callSite(fileID:line:column:)` / `.id(_:)` | `Effects.perform` | slot identity (call site by default, id when given) |
| `TaskKey(path:location:)` | `_bindEffectID` | the identity's bucket key |
| `GraphPath` | all handle plumbing | node identity for buckets and drop diagnostics |

Consumption notes:

- **Handle construction happens at mount for the root, per-derivation below it.** *(Amended by
  plan 04's SPI reconciliation.)* The host builds the root handle once with
  `_makeEffectsHandles(core:lens:.identity, path: GraphPath())`; the combinators derive child
  handles during `interact` through plan 04's pinned `Effects.appending(_:)`/`scoped(...)`
  SPI, implemented as an erased factory (`_EffectsHandleFactory` over `_ScopeLens`) carried by
  every handle. The enum-state pullback registers its presence watcher lazily on first
  derivation; `registerPresenceWatcher` is idempotent per path. Paths are identical to the
  retained-node-storage formulation because the tree is static.
- **Dismount behavior is plan 02's, unmodified**: post-dismount `modify`/`send` throw
  `CancellationError`; there is no dismount hook. `state` keeps reading through the core while
  it is alive (dismount cancels work but does not destroy state) and falls back to the
  handle's `lastKnownState` snapshot once the core is deallocated.
- **`EffectID` needs nothing from the core's launch path**: `perform(id:)` binds the
  identity's storage closures on first use, and the error-recording wrapper lives inside
  `perform` itself — so `launchEffect` stays id-agnostic. Because `perform`'s wrapper catches
  and records/reports every non-cancellation error before returning, the core's own catch-all
  in its launch loop is a second-layer backstop that never fires for handle-launched effects.
- **The synchronous single-domain commit funnel is load-bearing** for the departed-scope drop
  window (check-then-commit in the scoped closures); plan 02 §5 locks it.

## Test plan

New test files under `Tests/LatticeTests/` (harness details per plan 07; where the TestViewModel
isn't ready yet, these run against the raw core + handle directly):

`EffectsHandleTests.swift`
- `perform` during update launches; operation observes in-domain synchronous head start
  (mutation made before first `await` is visible immediately after `send` returns).
- `modify` from an effect (via the `EffectState` handle) runs the full funnel: domain state mutates and
  the projection diff fires observation.
- `send` from an effect (`effectState.send`) dispatches a fresh update phase.
- `effectState.state` inside an effect reflects mutations made after launch.
- Phase discipline is enforced by type: `Effects` has no `modify`/`send`/`state`, `EffectState` has
  no `perform`, so cross-phase misuse (`effects.modify` inside `interact`, `effectState.perform` inside an
  effect) does not compile — expressed as compile-fail notes (plan 03's compile-time negatives).
  The runtime backstops remain reachable only via a smuggled handle: `perform` outside update →
  issue reported, no task (`withExpectedIssue`); a smuggled `EffectState.modify`/`send` during the
  update phase → hard trap (covered by an `#if DEBUG` unit test on the precondition guard); a
  smuggled `effectState.state` read during the update phase lands on the core's named state-read
  precondition (plan 02's exit tests cover that trap).
- Dismount: `effectState.modify`/`effectState.send` after ViewModel teardown throw `CancellationError`; `effectState.state`
  falls back to the handle's last-read snapshot once the core is gone; issue reported only when
  the task isn't cancelled.
- Dynamic-member subscript write (`effectState.x = v`) runs exactly one funnel pass per
  assignment (mutate → transition detection → projection diff), matches a single-assignment
  `modify` call, and is silently dropped — no throw, no funnel run — once the handle is past
  dismount or its scope has departed; a subscript read equals the corresponding `state` read at
  the same point.
- Subscript write attempted from the update phase (a smuggled handle) hits the same named
  backstop as `modify`: the precondition trap, not Swift's opaque exclusivity crash.

`EffectCancellationTests.swift`
- Same `perform` call site, two dispatches: second `perform` cancels the first task (replace).
- Two different `perform` call sites in one update: both run to completion (track).
- Distinct `EffectID`s at one call site don't replace each other; same id (or same call site
  with no id) across dispatches does.
- Debounce-by-replacement with `TestClock`: three rapid `.queryChanged` dispatches reaching one
  `perform` line, advance clock, exactly one search executes.

`EffectIDTests.swift`
- `isRunning` true immediately after launch (head start), false after completion.
- `cancel()` from an effect cancels all attached tasks and returns one; from update phase →
  issue reported, nothing cancelled.
- `callAsFunction()` awaits completion and rethrows recorded error; `taskError` set on failure,
  `nil` after subsequent success, never set for `CancellationError`.
- `Storage.deinit` cancels the identity's bucket through its bound cancel closure.

`ScopedEffectsTests.swift` (the navigation-dismissed-mid-request contract)
- Child effect in flight, parent leaves the enum case → child's bucket cancelled by the funnel.
- Straggler `modify` after case departure: state unchanged, projection diff not run, no
  throw, `_EffectsDiagnostics.onDroppedReentry` fired with the child's `GraphPath` and
  `.modify`.
- Straggler `send` after case departure: no parent action observed, hook fired with `.send`.
- Optional-state variant (`\.destination.some…`) behaves identically on nil'ing.
- Key-path (struct) scoped child: never drops; `modify` writes through, `send` embeds.
- Nested `When` chains: drop detected at the departed level; grandchild paths cancelled by
  prefix.
- Case re-entered *after* departure: old straggler still drops (its tasks are dead); new
  dispatches launch fresh tasks under the same path.

All tests build with strict concurrency; none of the fixtures conform to `Sendable` — that
absence is itself part of the assertion.

## Acceptance gates

1. Public API surface matches the pinned README contract exactly: `Effects.perform` (update
   phase), `EffectState.modify/send/state` plus the dynamic-member subscript sugar (effect
   phase, passed to the `perform` closure), `EffectID` with
   `cancel`/`callAsFunction`/`isRunning`/`taskError`. Only defaulted source-location parameters
   beyond the pinned shapes; no other public additions.
2. No `Sendable` constraint or conformance anywhere in the new files; `Effects`, `EffectState`,
   `EffectID`, operation closures are all non-Sendable. `swift build` clean under Swift 6
   language mode.
3. `perform` is `@available(*, noasync)`; misuse messages match the TCA26-derived wording in
   this document verbatim.
4. Scope-departure drop contract passes `ScopedEffectsTests` including the DEBUG diagnostics
   hook; release builds compile the diagnostics away.
5. Every public member carries a DocC comment; `perform`'s documentation includes the
   `@concurrent`/`sending` escape-hatch guidance.
6. `swift test --filter EffectsHandleTests`, `--filter EffectCancellationTests`,
   `--filter EffectIDTests`, `--filter ScopedEffectsTests` green; full `swift test` green at
   integration time with plans 02/04.
7. Podspec builds without IssueReporting (the `latticeReportIssue` shim compiles under
   `#if canImport`).
8. Internal plumbing consumes only plan 02's §4 surface, reviewed against §"Consumed plan-02
   surface"; every handle and `EffectID` storage closure captures the core weakly.

## Risks

(Plan 02 seam drift is resolved by sequencing: this plan builds against plan 02's landed,
concrete `LatticeCore` surface, so there is no speculative seam left to drift.)

- **`send` drop on case departure is not README-pinned.** This plan extends the pinned `modify`
  drop to `send` for consistency. Alternative (deliver the embedded action anyway and let `When`
  routing no-op the child while parent leaves still see it) is a one-line change in the scoped
  `_send` closure; decide before plan 04 lands, update the README either way.
- **Hard `precondition` vs `reportIssue` asymmetry in the backstops** (trap for a smuggled
  `EffectState.modify`/`send` in the update phase, soft report for `perform` misuse) mirrors TCA26.
  Type separation makes the ordinary paths unreachable, so this only bites a handle deliberately
  smuggled across phases; an in-update `modify` re-enters the funnel under `inout` exclusivity
  and cannot be made safe (and an in-update `effectState.state` read lands on the core's named
  state-read precondition). Documented in the DocC comments.
- **Every handle closure must capture the root core weakly.** Plan 02's `deinit` confinement
  argument (its §10) depends on no cross-suspension strong references to the core outside the
  host. `_makeEffectsHandles` and `_bindEffectID` are the only places the captures live —
  gate 8 reviews them, and plan 02's TSan gate backs it.
- **No-`perform` call-site auto-cancel deliberately not adopted** (TCA26 cancels a location's
  tasks when its handler launches nothing); pinned off by plan 02 §5. Revisiting it later is
  core-side only — the handle API is unaffected — but it changes observable semantics and
  needs README sign-off.
- **One `EffectID` per tree node.** The identity's storage closures bind to the node of its
  first `perform(id:)`; launching the same identity from another node would key its tasks
  under a path the bound closures don't cancel or await. The static tree and the
  declare-in-interactor idiom make this a non-pattern; documented, and cheap to guard with an
  assertion in `_bindEffectID` if it ever bites.
