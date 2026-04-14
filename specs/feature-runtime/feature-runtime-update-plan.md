# Feature Runtime Update Plan

This document replaces the earlier "shared long-lived `FeatureRuntime` plus hooks/coordinator" direction with a no-hooks ownership model that is easier to reason about and closer to how TCA colocates execution with the owner of visible state.

It is written as an implementation handoff for an autonomous coding agent.

## Decision summary

The earlier plan pushed too much responsibility into [`FeatureRuntime.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift):

- execution engine
- state owner
- effect owner
- event source for consumers
- test seam

That is what made hooks/callbacks feel inevitable. The problem is not that callbacks are technically impossible to make work; the problem is that a long-lived runtime object needing registered observers is a smell in this architecture.

The updated direction is:

- do not add `FeatureRuntime.Hooks`
- do not add a production/test mode enum
- do not add a separate `Driver` abstraction
- collapse execution ownership upward
- let `ViewModel` own production execution
- let `TestViewModel` own test execution
- share the tricky semantics through small internal helper types/functions, not through a shared observable runtime object

In concrete terms:

- [`FeatureRuntime.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift) should be deleted by the end of the project
- `ViewModel` should inline the buffered send loop and root-scope effect bookkeeping it needs for production behavior
- `TestViewModel` should own its own buffered send loop and test-only receive bookkeeping
- shared logic should be extracted into internal helper files for action application, emission execution, root-scope tracking, and event-task creation

## Why this is the better boundary

### The hooks plan kept fighting ownership

The old plan tried to preserve one shared runtime by adding more observation points:

- `onStep`
- effect lifecycle hooks
- a coordinator above the runtime
- test-only buffering above eager runtime mutation

That keeps the fundamental split:

- runtime owns execution
- `ViewModel` / `TestViewModel` own visible state policy

Once async effects can keep mutating after `send` returns, the owner of execution and the owner of visible state must communicate somehow. If they are different objects, the communication seam keeps growing.

### TCA solves this at the ownership boundary, not with observers

TCA's production `Store`/`Core` owns:

- state
- buffered send loop
- effect re-entry

And `TestStore` gets its test seam by wrapping reducer execution before test-visible state advances, not by observing a separate runtime after the fact.

Lattice does not need to copy TCA's reducer DSL, but it should copy the colocated ownership idea:

- the object deciding visible production state should own production execution
- the object deciding visible test state should own test execution

That means `ViewModel` and `TestViewModel`, not a third long-lived engine object.

### No-hooks does not mean no shared code

This plan is not arguing for duplicating the hard parts. It is arguing for a different shape of reuse.

Good reuse:

- value types for bookkeeping
- helper functions for action application
- helper functions for emission spawning
- helper functions for root-scope `finish()` / cancellation

Bad reuse:

- a shared mutable runtime object that owns execution and asks consumers to observe it

## Architecture summary

The runtime should be decomposed into three layers:

1. Interactor mutation step
   - still synchronous
   - one action in
   - mutate domain state
   - return `Emission<Action>`

2. Shared execution helpers
   - pure or narrowly-scoped internal helpers
   - no registered observers
   - no public API
   - no long-lived "runtime owner" object

3. Public execution owners
   - `ViewModel<F>` for production
   - `TestViewModel<F>` for testing

The core invariant becomes:

- `ViewModel` owns production-visible state and production execution
- `TestViewModel` owns test-visible state and test execution
- both use the same internal helper semantics for buffered sends, root-scope ownership, effect spawning, cancellation, and finish/quiescence

## Proposed file layout

The exact filenames can be adjusted, but the split should look roughly like this:

```text
Sources/Lattice/Internal/FeatureRuntime.swift                       # delete
Sources/Lattice/Internal/Execution/ActionSource.swift
Sources/Lattice/Internal/Execution/ActionTransition.swift
Sources/Lattice/Internal/Execution/BufferedAction.swift
Sources/Lattice/Internal/Execution/SendScopeID.swift
Sources/Lattice/Internal/Execution/EffectID.swift
Sources/Lattice/Internal/Execution/RootScopeState.swift
Sources/Lattice/Internal/Execution/ApplyAction.swift
Sources/Lattice/Internal/Execution/EmissionExecution.swift
Sources/Lattice/Internal/Execution/RootScopeTasks.swift
Sources/Lattice/Presentation/ViewModel/ViewModel.swift             # move execution ownership here
Sources/Lattice/Presentation/ViewModel/EventTask.swift             # upgrade semantics
Sources/Lattice/Testing/TestViewModel/TestViewModel.swift
Sources/Lattice/Testing/TestViewModel/TestEventTask.swift
Sources/Lattice/Testing/TestViewModel/PendingReceive.swift
Sources/Lattice/Testing/TestViewModel/InFlightEffectRecord.swift
Sources/Lattice/Testing/TestViewModel/RootSendOrigin.swift
Sources/Lattice/Testing/TestViewModel/Exhaustivity.swift
Sources/Lattice/Testing/TestViewModel/TestFailure.swift
Sources/Lattice/Testing/InteractorTestHarness.swift                # delete
```

Optional internal helper split if files get too large:

```text
Sources/Lattice/Internal/Execution/AppendExecution.swift
Sources/Lattice/Internal/Execution/ObserveExecution.swift
Sources/Lattice/Internal/Execution/FinishSupport.swift
Sources/Lattice/Testing/TestViewModel/Internal/ReceiveMatching.swift
Sources/Lattice/Testing/TestViewModel/Internal/StateDiffing.swift
Sources/Lattice/Testing/TestViewModel/Internal/TimeoutSupport.swift
```

## Core internal helper types

These are shared semantics, not shared ownership.

```swift
import DequeModule
import Foundation
import OrderedCollections

enum ActionSource: Sendable {
    case sent
    case emitted
}

struct SendScopeID: Hashable, Sendable {
    let rawValue: UUID
}

struct EffectID: Hashable, Sendable {
    let rawValue: UUID
}

struct BufferedAction<Action: Sendable>: Sendable {
    let action: Action
    let source: ActionSource
    let rootScopeID: SendScopeID
}

struct ActionTransition<State: Sendable, Action: Sendable>: Sendable {
    let action: Action
    let source: ActionSource
    let previousState: State
    let currentState: State
    let emission: Emission<Action>
    let rootScopeID: SendScopeID
}

struct RootScopeState: Sendable {
    var bufferedActionCount = 0
    var inFlightEffectIDs: Set<EffectID> = []

    var isQuiescent: Bool {
        bufferedActionCount == 0 && inFlightEffectIDs.isEmpty
    }
}
```

Notes:

- These are cheap value types.
- None of them are observers.
- None of them know about `ViewModel` or `TestViewModel`.
- None of them carry test-only metadata like callsites or pending receives.

## Shared helper functions

### 1. Action application

The synchronous part of the old runtime becomes a helper function:

```swift
@MainActor
func applyAction<State: Sendable, Action: Sendable>(
    _ action: Action,
    source: ActionSource,
    rootScopeID: SendScopeID,
    to state: inout State,
    using interactor: AnyInteractor<State, Action>
) -> ActionTransition<State, Action> {
    let previousState = state
    let emission = interactor.interact(state: &state, action: action)
    return .init(
        action: action,
        source: source,
        previousState: previousState,
        currentState: state,
        emission: emission,
        rootScopeID: rootScopeID
    )
}
```

This is the only job the previously suggested `Driver` would have solved. A dedicated type is unnecessary.

### 2. Emission execution

The `.perform`, `.observe`, `.merge`, and `.append` logic should move into a small internal support layer that creates child tasks and re-enqueues emitted actions back into the owning object.

The key point:

- local closures passed into helper functions are acceptable
- long-lived observer registration is what this plan is rejecting

Example shape:

```swift
@MainActor
enum EmissionExecution {
    static func spawnTasks<Action: Sendable>(
        from emission: Emission<Action>,
        rootScopeID: SendScopeID,
        makeEffectID: () -> EffectID,
        effectDidStart: @MainActor @escaping (EffectID) -> Void,
        effectDidComplete: @MainActor @escaping (EffectID) -> Void,
        effectDidCancel: @MainActor @escaping (EffectID) -> Void,
        enqueueEmittedAction: @MainActor @escaping (Action, SendScopeID) -> Void
    ) -> [EffectID: Task<Void, Never>]
}
```

This layer is intentionally narrow:

- it does not own state
- it does not own queues
- it does not own visibility policy
- it only translates emissions into tasks with root-scope continuity

### 3. Root-scope task support

Production `EventTask` and test `TestEventTask` both need root-scope quiescence semantics.

Shared support should provide:

```swift
@MainActor
func makeRootScopeTask(
    rootScopeID: SendScopeID,
    isQuiescent: @MainActor @escaping (SendScopeID) -> Bool,
    cancelScope: @MainActor @escaping (SendScopeID) -> Void
) -> Task<Void, Never>
```

Implementation guidance:

- use flat state plus `Task.yield()` loops
- do not add per-scope continuations
- do not add detached task trees
- cancellation should cancel the currently tracked in-flight tasks for the root scope

## Production owner: `ViewModel`

`ViewModel` should become the owner of production execution. It no longer delegates to a long-lived `FeatureRuntime`.

### Proposed shape

```swift
@dynamicMemberLookup
@MainActor
public final class ViewModel<F: FeatureProtocol>: Observable, _ViewModel {
    public typealias Action = F.Action
    public typealias DomainState = F.DomainState
    public typealias ViewState = F.ViewState

    private var domainState: DomainState
    private var bufferedActions: Deque<BufferedAction<Action>> = []
    private var rootScopes: OrderedDictionary<SendScopeID, RootScopeState> = [:]
    private var effectTasks: OrderedDictionary<EffectID, Task<Void, Never>> = [:]
    private var isSending = false

    private var _viewState: ViewState

    private let interactor: AnyInteractor<DomainState, Action>
    private let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    private let areStatesEqual: (_ lhs: DomainState, _ rhs: DomainState) -> Bool
}
```

### Production send algorithm

`sendViewEvent(_:)` should:

1. create a fresh `SendScopeID`
2. enqueue the sent action
3. drain the buffered send loop if not already draining
4. return an `EventTask` bound to that root scope

Inside the loop:

1. dequeue the next buffered action
2. apply it with `applyAction`
3. commit `domainState = transition.currentState`
4. eagerly reduce `viewState` using today's same production rules
5. spawn child tasks from the returned emission
6. enroll those tasks into the same root scope

Effect-emitted actions re-enter by enqueueing another `BufferedAction` in the same root scope.

### Production view-state policy

Keep the existing `ViewModel` rule:

- reduce view state for emitted actions
- reduce for sent actions only when domain state meaningfully changed

That logic moves from the old step callback into a private method on `ViewModel`:

```swift
private func commitProductionTransition(
    _ transition: ActionTransition<DomainState, Action>
) {
    domainState = transition.currentState

    let shouldReduceViewState =
        transition.source == .emitted
        || !areStatesEqual(transition.previousState, transition.currentState)

    guard shouldReduceViewState else { return }
    viewStateReducer.reduce(transition.currentState, into: &viewState)
}
```

### Production `EventTask`

`EventTask` should stay public and lightweight, but its semantics should improve:

- `finish()` waits for root-scope quiescence
- `cancel()` cancels tasks currently enrolled in that root scope
- recursive effect work started by emitted actions is part of the same root scope

That fixes the current non-transitive weakness in [`EventTask.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/EventTask.swift).

## Test owner: `TestViewModel`

`TestViewModel` should own test execution directly, not sit above a runtime that it observes.

### Proposed shape

```swift
@MainActor
public final class TestViewModel<F: FeatureProtocol> {
    public typealias Action = F.Action
    public typealias DomainState = F.DomainState

    public private(set) var domainState: DomainState
    public var exhaustivity: Exhaustivity = .on

    private var assertedState: DomainState
    private var latestState: DomainState

    private var bufferedActions: Deque<BufferedAction<Action>> = []
    private var pendingReceives: Deque<PendingReceive<DomainState, Action>> = []
    private var rootScopes: OrderedDictionary<SendScopeID, RootScopeState> = [:]
    private var effectTasks: OrderedDictionary<EffectID, Task<Void, Never>> = [:]
    private var inFlightEffects: OrderedDictionary<EffectID, InFlightEffectRecord<Action>> = [:]
    private var rootSendOrigins: OrderedDictionary<SendScopeID, RootSendOrigin<Action>> = [:]
    private var isSending = false

    private let interactor: AnyInteractor<DomainState, Action>
}
```

### Test send algorithm

`send` should:

1. fail in exhaustive mode if pending receives exist
2. snapshot `assertedState`
3. create `SendScopeID`
4. store `RootSendOrigin`
5. enqueue the sent action
6. drain the buffered send loop
7. wait for effect startup long enough for immediate effects to register
8. assert the sent-state mutation
9. return `TestEventTask` bound to the root scope

### Test transition policy

The send loop is structurally the same as `ViewModel`'s, but visibility rules differ:

- `.sent` transition:
  - update `latestState`
  - update `assertedState`
  - update `domainState`

- `.emitted` transition:
  - update `latestState`
  - append `PendingReceive(action:resultingState:rootScopeID:)`
  - do not update `assertedState`
  - do not update `domainState`

This is the ownership collapse that replaces the old hooks/coordinator model. No callback is needed because the object performing the transition is also the object deciding whether to publish or buffer it.

### Test `receive`

`receive` does not re-enter execution. It only advances test-visible state using buffered receives:

```swift
public func receive(
    _ action: Action,
    timeout: Duration? = nil,
    assert update: ((inout DomainState) throws -> Void)? = nil,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async throws where Action: Equatable
```

Algorithm:

1. wait until a matching pending receive exists or timeout
2. in non-exhaustive mode, optionally skip earlier buffered receives
3. assert state mutation against `domainState`
4. commit `assertedState` and `domainState` to the pending receive's resulting state

### Test `finish`

Match TCA semantics:

- `TestViewModel.finish()` checks for unhandled receives first
- then waits for all in-flight effects to finish
- it does not auto-drain pending receives

`TestEventTask.finish()`:

- waits for quiescence of one root scope
- does not auto-drain pending receives

### Effect-start barrier

The old hooks plan used runtime effect events to feed a coordinator barrier. That is no longer needed.

`TestViewModel` can own its own startup barrier directly:

- create `AsyncStream.makeStream(of: SendScopeID.self)`
- when an effect for a root scope starts, yield that root scope ID
- after `send`, either:
  - return after the first started-effect signal for that root scope
  - or fast-path after one main-actor turn if the root scope produced no long-lived effect

This preserves the useful TCA behavior without a separate runtime observer layer.

## Test-only helper types

```swift
import Foundation
import OrderedCollections

struct RootSendOrigin<Action: Sendable>: Sendable {
    let action: Action
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt
}

struct PendingReceive<State: Sendable, Action: Sendable>: Sendable {
    let action: Action
    let resultingState: State
    let rootScopeID: SendScopeID
}

struct InFlightEffectRecord<Action: Sendable>: Sendable {
    let id: EffectID
    let rootScopeID: SendScopeID
}
```

These are all test-owned. None belong in shared production execution helpers.

## `FeatureRuntime` disposition

This plan's recommendation is to delete [`FeatureRuntime.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift), not preserve it as a smaller engine.

Reason:

- if `ViewModel` and `TestViewModel` own execution, `FeatureRuntime` no longer has a coherent job
- keeping it around as a mutable owner recreates the same seam pressure
- the only reusable parts left should be helper functions and bookkeeping types

The migration can temporarily keep the file while helpers are extracted, but the finished design should not leave a long-lived runtime object in place.

## Illustrative diffs

These are intentionally partial and schematic. They are meant to anchor the implementation, not apply cleanly as-is.

### 1. Delete the runtime owner

```diff
diff --git a/Sources/Lattice/Internal/FeatureRuntime.swift b/Sources/Lattice/Internal/FeatureRuntime.swift
deleted file mode 100644
--- a/Sources/Lattice/Internal/FeatureRuntime.swift
+++ /dev/null
@@
-@MainActor
-final class FeatureRuntime<State: Sendable, Action: Sendable> {
-    ...
-}
```

### 2. Move execution ownership into `ViewModel`

```diff
diff --git a/Sources/Lattice/Presentation/ViewModel/ViewModel.swift b/Sources/Lattice/Presentation/ViewModel/ViewModel.swift
@@
-    private let runtime: FeatureRuntime<DomainState, Action>
+    private var domainState: DomainState
+    private var bufferedActions: Deque<BufferedAction<Action>> = []
+    private var rootScopes: OrderedDictionary<SendScopeID, RootScopeState> = [:]
+    private var effectTasks: OrderedDictionary<EffectID, Task<Void, Never>> = [:]
+    private var isSending = false
@@
-        self.runtime = FeatureRuntime(
-            initialState: initialDomainState,
-            interactor: interactor
-        )
+        self.domainState = initialDomainState
+        self.interactor = interactor
@@
-        runtime.setStepHandler { [weak self] step in
-            guard let self else { return }
-            let shouldReduceViewState =
-                step.source == .emitted || !self.areStatesEqual(step.previousState, step.currentState)
-
-            guard shouldReduceViewState else { return }
-            self.viewStateReducer.reduce(step.currentState, into: &self.viewState)
-        }
+        // No runtime step handler. ViewModel now owns the send loop and commits view state directly.
@@
     @discardableResult
     public func sendViewEvent(_ event: Action) -> EventTask {
-        runtime.send(event)
+        let rootScopeID = SendScopeID(rawValue: UUID())
+        enqueue(event, source: .sent, rootScopeID: rootScopeID)
+        drainBufferedActionsIfNeeded()
+        return makeEventTask(for: rootScopeID)
     }
@@
-    deinit {
-        runtime.cancelAllEffects()
-    }
+    deinit {
+        cancelAllOwnedEffects()
+    }
```

### 3. `sendViewEvent` drain loop sketch

```swift
private func drainBufferedActionsIfNeeded() {
    guard !isSending else { return }
    isSending = true
    defer { isSending = false }

    while let buffered = bufferedActions.popFirst() {
        rootScopes[buffered.rootScopeID, default: .init()].bufferedActionCount -= 1

        var workingState = domainState
        let transition = applyAction(
            buffered.action,
            source: buffered.source,
            rootScopeID: buffered.rootScopeID,
            to: &workingState,
            using: interactor
        )

        commitProductionTransition(transition)
        spawnEffects(
            from: transition.emission,
            rootScopeID: buffered.rootScopeID
        )

        pruneRootScopeIfQuiescent(buffered.rootScopeID)
    }
}
```

### 4. Test send loop shape

```swift
private func commitTestTransition(
    _ transition: ActionTransition<DomainState, Action>
) {
    latestState = transition.currentState

    switch transition.source {
    case .sent:
        assertedState = transition.currentState
        domainState = transition.currentState

    case .emitted:
        pendingReceives.append(
            .init(
                action: transition.action,
                resultingState: transition.currentState,
                rootScopeID: transition.rootScopeID
            )
        )
    }
}
```

### 5. Shared emission spawning helper

```swift
private func spawnEffects(
    from emission: Emission<Action>,
    rootScopeID: SendScopeID
) {
    let spawned = EmissionExecution.spawnTasks(
        from: emission,
        rootScopeID: rootScopeID,
        makeEffectID: { EffectID(rawValue: UUID()) },
        effectDidStart: { [weak self] effectID in
            self?.enrollEffect(effectID, rootScopeID: rootScopeID)
        },
        effectDidComplete: { [weak self] effectID in
            self?.completeEffect(effectID, rootScopeID: rootScopeID)
        },
        effectDidCancel: { [weak self] effectID in
            self?.cancelEffect(effectID, rootScopeID: rootScopeID)
        },
        enqueueEmittedAction: { [weak self] action, rootScopeID in
            self?.enqueue(action, source: .emitted, rootScopeID: rootScopeID)
            self?.drainBufferedActionsIfNeeded()
        }
    )

    for (effectID, task) in spawned {
        effectTasks[effectID] = task
    }
}
```

The closure use here is local task wiring, not a settable runtime observer API.

## Event-task semantics

### `EventTask`

Current behavior in [`EventTask.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/EventTask.swift) is too shallow for recursive emissions.

After this update:

- `EventTask` should represent one root send scope
- `finish()` waits until the owning `ViewModel` reports that scope quiescent
- `cancel()` cancels all currently tracked effect tasks in the scope

### `TestEventTask`

`TestEventTask` mirrors TCA:

- async `cancel()`
- timeout-aware `finish()`
- finish waits for root-scope quiescence only
- finish does not drain pending receives

## Interactor test migration

There is still no compatibility period for [`InteractorTestHarness.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift).

However, in this design the replacement does not depend on a shared runtime object:

```swift
let feature = Feature(
    interactor: CounterInteractor(),
    reducer: BuildViewState<CounterState, CounterState> { domainState, viewState in
        viewState = domainState
    }
)

let model = TestViewModel(
    initialDomainState: CounterState(),
    feature: feature
)
```

Tests should migrate directly to `TestViewModel` and the harness should then be deleted.

## Phased implementation plan

### Phase 1: Extract reusable execution primitives

Status: completed on April 14, 2026.

Files:

- new `Sources/Lattice/Internal/Execution/*`
- [`FeatureRuntime.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift) temporarily still present

Work:

1. Add `ActionSource`, `ActionTransition`, `BufferedAction`, `SendScopeID`, `EffectID`, and `RootScopeState`.
2. Add `applyAction`.
3. Add `EmissionExecution.spawnTasks`.
4. Add shared root-scope task/quiescence support.
5. Keep helpers `@MainActor`.

Acceptance:

- helper-level tests prove `.perform`, `.observe`, `.merge`, and `.append` preserve current ordering and cancellation behavior
- no public API changes yet

### Phase 2: Move production ownership into `ViewModel`

Status: completed on April 14, 2026.

Files:

- [`ViewModel.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift)
- [`EventTask.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/EventTask.swift)

Work:

1. Remove the stored `FeatureRuntime`.
2. Add buffered send-loop state directly to `ViewModel`.
3. Inline production transition commits into `ViewModel`.
4. Upgrade `EventTask` to root-scope semantics.
5. Keep public `ViewModel` API unchanged.

Acceptance:

- existing `ViewModel` tests pass unchanged
- production eager view-state updates remain intact
- `EventTask.finish()` becomes transitive over recursive child emissions

### Phase 3: Add `TestViewModel` on the same helper semantics

Files:

- `TestViewModel.swift`
- `TestEventTask.swift`
- `PendingReceive.swift`
- `InFlightEffectRecord.swift`
- `RootSendOrigin.swift`
- `Exhaustivity.swift`
- `TestFailure.swift`

Work:

1. Implement test-owned buffered send loop.
2. Add pending receive queue and in-flight effect tracking.
3. Add effect-start barrier directly in `TestViewModel`.
4. Implement `send`, `receive`, `finish`, `skipReceivedActions`, and `skipInFlightEffects`.
5. Add exact-action, predicate, and case-path receive overloads.

Acceptance:

- `TestViewModel` reproduces the intended TCA-like send/receive/finish semantics
- pending receives remain buffered until explicitly received or skipped

### Phase 4: Remove `FeatureRuntime`

Files:

- [`FeatureRuntime.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift)
- any now-obsolete runtime files

Work:

1. Delete the long-lived runtime type.
2. Remove any remaining references from production or testing.
3. Delete any runtime-only registry code that no longer has a coherent purpose.

Acceptance:

- `rg -n "FeatureRuntime" Sources Tests ExampleProject` only finds historical/spec references or intentionally renamed helper text

### Phase 5: Remove `InteractorTestHarness` and migrate tests

Files:

- harness-based test files
- [`InteractorTestHarness.swift`](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/InteractorTestHarness.swift)

Work:

1. Port harness tests to `TestViewModel`.
2. Remove ad hoc `Task.yield()` / `Task.sleep()` settling where the new ownership model makes it unnecessary.
3. Delete the harness.

Acceptance:

- `rg -n "InteractorTestHarness" README.md Sources Tests ExampleProject` is empty except for intentional historical/spec references
- timing-sensitive tests are deterministic under the new test owner

### Phase 6: Docs and cleanup

Files:

- [`README.md`](/Users/michaelbattaglia/Documents/lattice/lattice/README.md)
- [`specs/feature-runtime/README.md`](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-runtime/README.md)
- [`specs/feature-runtime/implementation-plans.md`](/Users/michaelbattaglia/Documents/lattice/lattice/specs/feature-runtime/implementation-plans.md)

Work:

1. Remove references to hooks/coordinator architecture.
2. Present `TestViewModel<F>` as the only testing lane.
3. Document the ownership-collapsed design.

Acceptance:

- spec language no longer presents hooks as the target design

## Test matrix

Add or update suites for:

- `ViewModelExecutionTests`
- `ViewModelAppendTests`
- `EventTaskTests`
- `TestViewModelSendTests`
- `TestViewModelReceiveTests`
- `TestViewModelFinishTests`
- `TestViewModelExhaustivityTests`
- `TestViewModelFailureTests`
- `TestViewModelAppendTests`
- `TestViewModelObserveTests`
- `TestViewModelCancellationTests`
- helper-level execution tests for `.perform`, `.observe`, `.append`, and recursive emissions

Focused verification commands:

```bash
swift test --filter ViewModel
swift test --filter EventTaskTests
swift test --filter TestViewModel
swift test --filter Append
swift test --filter Observe
swift test
```

## Diagnostics

Diagnostics stay public and test-owned.

Must-have categories:

1. Must handle received actions before sending another action.
2. Unexpected received actions left unhandled at `finish()` / teardown.
3. Expected to receive action, but none arrived before timeout.
4. Received unexpected action before this one.
5. Expected effects to finish, but some remain in flight.
6. Skipped received actions.
7. Skipped in-flight effects.
8. State mutation did not match expectation.
9. Assertion closure made no changes when a change was expected.

The key design constraint:

- diagnostics belong to `TestViewModel` and helper diffing code
- diagnostics do not belong to production execution helpers

## Risks

### Risk 1: accidental semantic drift between `ViewModel` and `TestViewModel`

Mitigation:

- keep action application and emission spawning in shared helpers
- duplicate only visibility policy and public API behavior

### Risk 2: hiding a runtime object behind another name

Mitigation:

- do not replace `FeatureRuntime` with another long-lived "engine" that consumers observe
- helper files should be helpers, not a renamed central mutable owner

### Risk 3: over-abstracting shared code

Mitigation:

- do not add protocols or generic observer layers to eliminate small duplication
- prefer a little duplication in send-loop owners over a large abstraction that obscures ownership

### Risk 4: transitive finish still implemented shallowly

Mitigation:

- root-scope bookkeeping must be authoritative for both production and test task handles
- emitted child work must stay enrolled in the originating root scope

### Risk 5: local helper closures accidentally reintroduce the same smell

Mitigation:

- allow closures only as local task-wiring implementation details
- do not store them as long-lived observer registrations on a shared runtime object

## Final recommendation

Ship the ownership collapse.

This is the cleanest way to remove the hooks smell without backsliding into a mode enum or inventing a redundant driver:

- no long-lived observable `FeatureRuntime`
- `ViewModel` owns production execution
- `TestViewModel` owns test execution
- shared internal helpers preserve common semantics
- transitive root-scope ownership remains the backbone of `finish()` and cancellation
- `InteractorTestHarness` still exits in the final state
