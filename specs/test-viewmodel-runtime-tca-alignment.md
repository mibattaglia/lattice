# TestViewModel Runtime Alignment with TCA Themes

Status: proposed follow-up design for phase 2 runtime refinement.

Related:
- [TestViewModel: Feature-First Testing Runtime](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md)
- Local TCA reference repo: `/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture`

## Purpose

This document tightens the runtime design for `TestViewModel` by re-anchoring it to the proven runtime themes used by TCA's `Store` and `TestStore`, while preserving Lattice's terminology and public architecture:

- Lattice uses **interactors**, not reducers.
- Lattice uses **emissions**, not effects.
- Lattice remains **feature-first** at the public API layer.

The goal is not to turn Lattice into TCA, nor to reproduce TCA's current implementation details literally. The goal is to copy the invariants that make TCA's runtime and testing story deterministic, comprehensible, and resilient under async work, and adapt those invariants to Lattice's async-native, layered architecture.

## Why This Change Is Necessary

The current phase 2 implementation moved in the right direction by introducing a shared runtime and `TestViewModel`, but it still diverges from TCA in a few ways that materially increase brittleness:

1. `TestViewModel` still compensates for runtime timing with `Task.yield()` and polling.
2. `FeatureRuntime` still models sequential `.append` via origin-wide in-flight counting rather than a more direct execution primitive.
3. Cancellation is still primarily caller-owned through task handles rather than feature-owned through the runtime/emission model.
4. View-state reduction decisions are still partially duplicated in facade layers instead of being derived from one canonical runtime contract.

These problems matter because they undermine the main selling points of the new testing story:

- deterministic startup boundaries;
- step-wise `send`/`receive`;
- exhaustive buffering semantics;
- production and test execution sharing one engine;
- fewer sleeps/yields in tests.

TCA has already solved the hard parts of this problem at the architectural level. Lattice should reproduce those guarantees in terms of interactors, emissions, and view-state facades rather than reducers, effects, and Combine publishers.

## TCA Runtime Patterns to Copy

### 1. Root send loop with buffered actions

TCA's core runtime buffers actions and processes them through one root send loop rather than recursively mutating state as actions arrive.

Primary references:
- [Core.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Core.swift)
- [Core.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Core.swift): `RootCore._send`

Important properties of the TCA design:
- user-origin sends are distinguished from effect-origin sends;
- reentrant user sends are guarded against;
- state is reduced through a local `currentState` during the synchronous reduction wave;
- effect-fed actions are re-enqueued into the same loop;
- the caller gets a task handle representing work started from the send.

This is the most important runtime behavior to copy.

### 2. Thin facade over a smaller core

TCA keeps `Store` thin and hides actual send/state/effect logic behind `Core` / `RootCore`.

Primary references:
- [Store.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Store.swift)
- [Core.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Core.swift)

Lattice should similarly keep:
- `ViewModel`
- `TestViewModel`
as thin facades over one shared runtime.

### 3. Distinct sent-vs-received test events

TCA's `TestStore` does not treat received actions as "just more actions". It buffers them as distinct test-runtime events.

Primary references:
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift)
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift): `receivedActions`

Important properties:
- sent actions and received actions are explicitly distinguished;
- only received actions are buffered;
- each buffered item stores the post-reduce state snapshot;
- `receive` advances asserted state to that snapshot.

This is exactly the model Lattice should use for `TestViewModel`.

### 4. Exhaustivity changes runtime behavior, not just messaging

TCA's exhaustivity mode changes:
- whether buffered receives block `send`;
- whether skipped receives are auto-cleared;
- whether teardown tolerates in-flight work;
- whether skipped assertions are reported informatively.

Primary references:
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift): `Exhaustivity`
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift): `send`
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift): `receive`

Lattice should mirror that behavioral split, even if the exact async waiting mechanisms differ from TCA's current implementation.

### 5. Separate "received outputs" from "in-flight work"

TCA keeps buffered received actions and in-flight effects as separate concepts.

Primary references:
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift): `receivedActions`
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift): `inFlightEffects`

This matters because:
- `receive` should wait for buffered outputs;
- `finish` should wait for in-flight work;
- `skipReceivedActions()` should not mean "cancel tasks";
- `skipInFlightEffects()` should not mean "consume outputs".

Lattice should preserve this distinction, but with Lattice language:
- "received actions from emissions"
- "in-flight emissions"

### 6. Feature-owned cancellation identities

TCA's cancellation model is not centered on the returned task handle. It is centered on cancellation IDs in the effect model itself. Lattice should copy that ownership model even though it will implement it with its own async runtime structures.

Primary references:
- [Cancellation.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift)

This is necessary in Lattice because long-living observation, debouncing, and replacement should be controlled by the interactor/runtime, not only by UI/test code holding an `EventTask`.

## Lattice Target Design

## Runtime goals

`FeatureRuntime` should become the one true execution engine for:
- sent actions;
- emission-fed actions;
- emission registration;
- cancellation bookkeeping hooks;
- runtime step callbacks.

It should not own:
- asserted test state;
- buffered received-step queues;
- view-state assertions;
- exhaustivity policy.

Those are test-facade concerns.

## Runtime model

```swift
@MainActor
final class FeatureRuntime<State: Sendable, Action: Sendable> {
    enum ActionSource: Sendable {
        case sent
        case receivedEmission
    }

    struct RuntimeStep: Sendable {
        let action: Action
        let source: ActionSource
        let previousState: State
        let currentState: State
        let originID: UUID
    }

    struct RuntimeSendResult: Sendable {
        let originID: UUID
        let startedEmissionCount: Int
    }

    var onStep: (@MainActor (RuntimeStep) -> Void)?

    func send(_ action: Action, source: ActionSource) -> RuntimeSendResult
    func finish(originID: UUID, timeout: Duration?) async -> FinishResult
    func finish(timeout: Duration?) async -> FinishResult
}
```

### Invariants

1. User-origin `send` enters one buffered root loop.
2. Synchronous `.action` emissions are re-enqueued into that same loop.
3. State mutation is serialized through one main-actor queue.
4. `send` does not return until:
   - the synchronous reduction wave is complete;
   - immediate async emissions have been registered;
   - `.observe` subscriptions have started;
   - `.append` has registered its coordinator;
   - `.merge` has registered its children.
5. `send` does not wait for started emissions to finish.

These startup guarantees are intentionally stronger and more explicit than what current TCA exposes publicly. They are the async-native Lattice adaptation of TCA's effect-startup boundary, not a claim of implementation parity.

## Task bag goals

Keep one deliberately tiny nonisolated helper for:
- raw task storage;
- synchronous cancellation during `deinit`;
- origin-scoped bookkeeping needed by `EventTask` and `TestEventTask`.

It should not own runtime semantics.

```swift
final class EmissionTaskRegistry: @unchecked Sendable {
    func insert(task: Task<Void, Never>, taskID: UUID, originID: UUID)
    func remove(taskID: UUID, originID: UUID)
    func cancel(originID: UUID)
    func cancelAll()
    func isCancelled(originID: UUID) -> Bool
}
```

## Test runtime goals

`TestViewModel` should mimic `TestStore`:

- `send` applies and asserts immediate state mutation;
- received actions from emissions are buffered;
- `receive` dequeues one buffered received step and asserts against its exact post-reduce snapshot;
- `finish` asserts that no received actions remain, then waits for in-flight emissions to drain;
- non-exhaustive mode can skip buffered receives and/or skip in-flight emission bookkeeping.

## Concrete Changes

### Change 1: Replace recursive send with a buffered root loop

Current problem:
- recursive runtime send behavior forces the test layer to use `Task.yield()` and polling to detect when the runtime has settled enough to assert against.

Necessary change:
- `FeatureRuntime.send` must enqueue actions into a buffered root loop.

### Before

```swift
// Simplified current shape
func send(_ action: Action, source: ActionSource = .sent, originID: UUID? = nil) -> RuntimeSendResult {
    let emission = interactor.interact(state: &state, action: action)
    onStep?(...)
    let startedEmissionCount = spawnTasks(from: emission, originID: resolvedOriginID)
    return RuntimeSendResult(...)
}
```

### After

```diff
 @MainActor
 final class FeatureRuntime<State: Sendable, Action: Sendable> {
-    private(set) var state: State
-    private let interactor: AnyInteractor<State, Action>
+    private(set) var state: State
+    private let interactor: AnyInteractor<State, Action>
+    private var bufferedActions: [(action: Action, source: ActionSource, originID: UUID)] = []
+    private var isSending = false

     @discardableResult
     func send(
         _ action: Action,
         source: ActionSource = .sent,
         originID: UUID? = nil
     ) -> RuntimeSendResult {
-        let resolvedOriginID = originID ?? UUID()
-        let previousState = state
-        let emission = interactor.interact(state: &state, action: action)
-        onStep?(...)
-        let startedEmissionCount = spawnTasks(from: emission, originID: resolvedOriginID)
-        return RuntimeSendResult(originID: resolvedOriginID, startedEmissionCount: startedEmissionCount)
+        let resolvedOriginID = originID ?? UUID()
+        bufferedActions.append((action, source, resolvedOriginID))
+        guard !isSending else {
+            return RuntimeSendResult(originID: resolvedOriginID, startedEmissionCount: 0)
+        }
+
+        isSending = true
+        var currentState = state
+        defer {
+            bufferedActions.removeAll()
+            state = currentState
+            isSending = false
+        }
+
+        var totalStartedEmissionCount = 0
+        var index = bufferedActions.startIndex
+        while index < bufferedActions.endIndex {
+            let buffered = bufferedActions[index]
+            let previousState = currentState
+            let emission = interactor.interact(state: &currentState, action: buffered.action)
+            onStep?(
+                RuntimeStep(
+                    action: buffered.action,
+                    source: buffered.source,
+                    previousState: previousState,
+                    currentState: currentState,
+                    originID: buffered.originID
+                )
+            )
+            totalStartedEmissionCount += spawnTasks(
+                from: emission,
+                originID: buffered.originID
+            )
+            index += 1
+        }
+
+        return RuntimeSendResult(
+            originID: resolvedOriginID,
+            startedEmissionCount: totalStartedEmissionCount
+        )
     }
 }
```

### Why this is necessary

This is the runtime change that makes TCA's `Store` predictable, and it is the single most important part to preserve in Lattice. Without it:
- synchronous `.action` waves are harder to reason about;
- user reentrancy is poorly defined;
- the runtime cannot establish a clean "send is now settled enough to assert immediate state" boundary;
- tests compensate with yields and polling.

This is the single highest-priority runtime change.

TCA reference:
- [Core.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Core.swift)

### Change 2: Register emission subscriptions deterministically

Current problem:
- tests still need runtime yielding because the runtime has no explicit subscription-start boundary.

Necessary change:
- `.perform`, `.observe`, `.merge`, and `.append` must all synchronously register themselves before `send` returns.

### Before

```swift
case .observe(let stream):
    let task = Task { ... let sourceStream = await stream() ... }
    taskRegistry.insert(task: task, ...)
```

### After

```diff
 case .observe(let stream):
     let taskID = registerTrackedEmission(originID: originID)
-    let task = Task { [weak self] in
-        let sourceStream = await stream()
-        for await action in sourceStream { ... }
-    }
+    let sourceStreamTask = Task { await stream() }
+    let task = Task { [weak self] in
+        let sourceStream = await sourceStreamTask.value
+        await MainActor.run {
+            self?.markEmissionSubscriptionStarted(taskID, originID: originID)
+        }
+        for await action in sourceStream { ... }
+    }
     taskRegistry.insert(task: task, taskID: taskID, originID: originID)
```

### Why this is necessary

TCA's `TestStore.send` distinguishes between the immediate `send` boundary and later effect completion, but it does not expose the exact startup contract Lattice needs for async streams and layered test/runtime coordination. Lattice therefore needs its own explicit startup contract so that:
- analytics-like side effects can be asserted right after `await model.send(...)`;
- tests stop needing ad hoc yields;
- `.observe` is not a race between subscription and the next assertion.

This is an adaptation of TCA's effect-startup/testing theme rather than a direct translation of the current implementation.

TCA references:
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift)
- [Core.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Core.swift)

### Change 3: Add emission cancellation identities to the public runtime model

Current problem:
- cancellation is mostly caller-owned through `EventTask`.
- the interactor cannot naturally express replacement or long-living emission teardown as part of domain logic.

Necessary change:
- add cancellation identity support to `Emission`.

### Before

```swift
case .perform(work: @Sendable () async -> Action?)
case .observe(stream: @Sendable () async -> AsyncStream<Action>)
```

### After

```diff
 public struct Emission<Action: Sendable>: Sendable {
+    public struct Cancellation: Sendable {
+        public let id: AnyHashable
+        public let cancelInFlight: Bool
+    }
+
     public enum Kind: Sendable {
         case none
         case action(Action)
-        case perform(work: @Sendable () async -> Action?)
-        case observe(stream: @Sendable () async -> AsyncStream<Action>)
+        case perform(
+            work: @Sendable () async -> Action?,
+            cancellation: Cancellation?
+        )
+        case observe(
+            stream: @Sendable () async -> AsyncStream<Action>,
+            cancellation: Cancellation?
+        )
         case merge([Emission<Action>])
         case append([Emission<Action>])
+        case cancel(id: AnyHashable)
     }
 }
```

Possible API sugar:

```swift
extension Emission {
    public func cancellable(
        id: some Hashable & Sendable,
        cancelInFlight: Bool = false
    ) -> Self

    public static func cancel(id: some Hashable & Sendable) -> Self
}
```

### Why this is necessary

This is the TCA ownership lesson that matters most after the buffered send loop.

Without feature-owned cancellation IDs:
- debouncing is more bespoke than it needs to be;
- long-living observation teardown is harder to model declaratively;
- caller-owned task handles become too important;
- there is no general-purpose "cancel the previous emission for this feature concern" primitive.

Lattice does not need to copy TCA's exact cancellation machinery or scoping internals here. It does need to move cancellation ownership into the emission model itself.

TCA reference:
- [Cancellation.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift)

### Change 4: Rework `.append` sequencing to use direct child completion

Current problem:
- `.append` currently sequences by waiting for the origin-wide in-flight emission count to fall back to a magic threshold.

Necessary change:
- `.append` should coordinate against direct child completion, not global origin state.

### Before

```swift
for emission in emissions {
    _ = self.spawnTasks(from: emission, originID: originID)
    await self.waitForOriginEmissionCount(originID, targetCount: 1)
}
```

### After

```diff
 case .append(let emissions):
     let coordinatorTaskID = registerTrackedEmission(originID: originID)
     let task = Task { @MainActor [weak self] in
         guard let self else { return }
         for emission in emissions {
-            _ = self.spawnTasks(from: emission, originID: originID)
-            await self.waitForOriginEmissionCount(originID, targetCount: 1)
+            let childHandle = self.startEmissionSequenceChild(
+                emission,
+                originID: originID
+            )
+            await childHandle.finish()
         }
         self.finishTrackedEmission(originID: originID, taskID: coordinatorTaskID)
     }
```

This does not mean the public `Emission.append` API goes away. It means the runtime implementation becomes more explicit and less fragile.

This section is best understood as Lattice's async-native equivalent of TCA's `Effect.concatenate` semantics, not as a claim about `Store`/`Core` internals specifically.

### Why this is necessary

Global origin counters are an implementation detail. `.append` ordering should not depend on the entire origin tree happening to have the right count at the right time.

This is one of the main places where current Lattice still feels less robust than TCA.

### Change 5: Remove polling from `TestViewModel`

Current problem:
- `TestViewModel.send` and `receive` still use `Task.yield()`/polling to discover when the runtime has reached the next observable boundary.

Necessary change:
- drive `TestViewModel` from runtime callbacks and explicit wait channels, not polling.

### Before

```swift
let result = runtime.send(action)
if result.startedEmissionCount > 0 {
    await Task.yield()
}
```

and

```swift
while bufferedReceivedSteps.isEmpty {
    guard clock.now < deadline else { return nil }
    await Task.yield()
}
```

### After

```diff
 @MainActor
 public final class TestViewModel<F: FeatureProtocol> {
+    private var sentStepContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
+    private var receivedActionContinuations: [CheckedContinuation<Void, Never>] = []

     public func send(...) async -> TestEventTask {
         let result = runtime.send(action)
-        if result.startedEmissionCount > 0 { await Task.yield() }
+        await waitForSentStep(originID: result.originID)
         ...
     }

     private func nextReceivedStep(timeout: Duration) async -> ReceivedStep? {
         if let first = bufferedReceivedSteps.first { return first }
-        while bufferedReceivedSteps.isEmpty { await Task.yield() }
+        return await waitForReceivedStep(timeout: timeout)
     }
 }
```

### Why this is necessary

This is the most visible test-runtime mismatch with the spirit of TCA's testing model. Current `TestStore` still uses yielding and polling internally in places, but Lattice is in a position to expose stronger runtime-owned synchronization boundaries directly.

Lattice should take that opportunity.

TCA reference:
- [TestStore.swift](/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/TestStore.swift)

### Change 6: Buffer received steps exactly like `TestStore`

Current problem:
- Lattice is close here, but it still needs to align more precisely with the TCA buffering model.

Necessary change:
- the receive queue should be authoritative and store post-reduce snapshots.

```swift
struct ReceivedStep<State, ViewState, Action> {
    let action: Action
    let domainState: State
    let viewState: ViewState
    let originID: UUID
}
```

Rules:
- only actions fed back from emissions enter the queue;
- `receive` pops the first buffered item in exhaustive mode;
- in non-exhaustive mode, `receive` may match a later item and skip earlier ones while advancing asserted state;
- `finish` must fail if buffered items remain.

This is already directionally in the original plan and should now be made normative by aligning with TCA's test semantics rather than every implementation detail.

### Change 7: Align `skipInFlightEffects` semantics intentionally

Current problem:
- the current Lattice behavior cancels underlying runtime work.
- TCA's `skipInFlightEffects()` is bookkeeping-oriented and does not necessarily tear down the underlying work.

Necessary design decision:
- choose one behavior deliberately and document the difference.

Recommendation:
- if strict semantic alignment is the goal, Lattice should make `skipInFlightEffects()` bookkeeping-oriented.
- if Lattice prefers stronger teardown guarantees, rename it to communicate that difference.

Suggested rename:

```diff
-skipInFlightEffects()
+skipInFlightEffectsTracking()
```

or, if cancellation is desired:

```diff
-skipInFlightEffects()
+cancelInFlightEffects()
```

Because Lattice uses "emissions", a future Lattice-native naming pass may prefer:

```swift
skipInFlightEmissions()
cancelInFlightEmissions()
```

### Change 8: Centralize view-state reduction decisions with a shared helper

Current problem:
- view-state update logic is still duplicated between `ViewModel` and `TestViewModel`.
- both facades independently decide when a domain-state transition should produce a presentation update.
- both facades independently maintain the reduction base used for the next `viewStateReducer.reduce` call.
- test buffering means the two facades are already operating over different presentation timelines:
  - `ViewModel` reduces into currently visible `viewState`;
  - `TestViewModel` reduces into asserted or buffered-tail view state.

Necessary change:
- derive one canonical presentation-relevance rule from runtime steps.
- let facades call that shared helper rather than re-implement the decision logic themselves.

### Before

Two different facades each reason about:

```swift
step.source == .emitted || !areStatesEqual(step.previousState, step.currentState)
```

That rule currently lives in multiple places, which is a drift risk. Any future change to runtime semantics requires synchronized edits in every facade.

### After

```diff
 @MainActor
 final class FeatureRuntime<State, Action> {
+    func shouldReducePresentation(
+        for step: RuntimeStep,
+        areStatesEqual: @Sendable (State, State) -> Bool
+    ) -> Bool {
+        step.source == .receivedEmission
+            || !areStatesEqual(step.previousState, step.currentState)
+    }
 }

 @MainActor
 public final class ViewModel<F: FeatureProtocol> {
+    runtime.onStep = { [weak self] step in
+        guard let self else { return }
+        guard runtime.shouldReducePresentation(for: step, areStatesEqual: self.areStatesEqual)
+        else { return }
+        self.viewStateReducer.reduce(step.currentState, into: &self.viewState)
+    }
 }

 @MainActor
 public final class TestViewModel<F: FeatureProtocol> {
+    private func handle(step: FeatureRuntime<DomainState, Action>.RuntimeStep) {
+        var nextViewState = bufferedViewState
+        if runtime.shouldReducePresentation(for: step, areStatesEqual: areStatesEqual) {
+            viewStateReducer.reduce(step.currentState, into: &nextViewState)
+        }
+        ...
+    }
 }
```

Suggested helper:

```swift
func shouldReducePresentation(
    for step: RuntimeStep,
    areStatesEqual: @Sendable (State, State) -> Bool
) -> Bool {
    step.source == .receivedEmission
        || !areStatesEqual(step.previousState, step.currentState)
}
```

### Why this is necessary

This is necessary for three reasons:

1. Drift prevention
   - `ViewModel` and `TestViewModel` should not each embed their own copy of the presentation-relevance rule.
   - They should call one shared helper.

2. Future runtime growth
   - today the distinction is only `sent` vs `receivedEmission`;
   - later the runtime may grow more nuanced step kinds or scoped child-feature semantics;
   - only the shared runtime helper should need to know how those affect presentation.

3. Buffered test correctness
   - `TestViewModel` already has a more complex presentation timeline than `ViewModel`;
   - if both facades independently decide whether a transition is presentation-relevant, they will eventually disagree in subtle buffered cases.

This is not the first runtime change to make, but it is one of the clearest long-term drift reducers.

### Suggested acceptance criteria

- `ViewModel` no longer computes its own `shouldReduceViewState` rule inline.
- `TestViewModel` no longer computes its own `shouldReduceViewState` rule inline.
- `FeatureRuntime` exposes one canonical helper for presentation relevance.
- production and test facades reduce view state in the same order for the same runtime steps.
- adding a new runtime step source kind requires updating only the shared helper.

## Proposed New Internal Layout

```text
Sources/Lattice/Internal/
  FeatureRuntime.swift
  EmissionTaskRegistry.swift
  RuntimeSendLoop.swift            // optional extraction if FeatureRuntime grows
  RuntimeCancellationRegistry.swift // optional if cancellation IDs become richer

Sources/Lattice/Testing/
  TestViewModel.swift
  TestEventTask.swift
```

The key point is not the filenames. The key point is that all execution semantics live in one runtime path, while Lattice-specific presentation concerns are still derived from that runtime rather than independently reinterpreted by facades.

## Suggested Acceptance Criteria

### Runtime
- No facade needs `Task.yield()` to know when `send` has reached its immediate assertion boundary.
- User-origin sends are guarded against reentrant processing.
- Synchronous `.action` emissions feed back through one buffered loop.
- `.observe` startup is registered before `send` returns.
- `.append` sequencing does not depend on global origin-count heuristics.

### Testing
- `TestViewModel.send` never polls for sent-step visibility.
- `TestViewModel.receive` never polls for buffered receives.
- Exhaustive mode blocks `send` while buffered receives exist.
- `finish` first asserts no buffered receives remain, then waits for in-flight emissions.
- Non-exhaustive mode can skip buffered receives and optionally report skipped assertions.

### Cancellation
- Interactors can mark emissions as cancellable by identity.
- Replacement/cancel-in-flight behavior is owned by the runtime model, not only by task handles.
- Long-living observation can be modeled without requiring the caller to hold the returned task.

## Migration Plan

1. Land the buffered root send loop.
2. Replace test-layer polling with explicit runtime synchronization.
3. Introduce cancellation IDs for `Emission`.
4. Rework `.append` sequencing to use direct child completion.
5. Revisit `skipInFlightEffects` naming/semantics to either match TCA or clearly differ from it.
6. Centralize view-state reduction decisions.

## Recommendation

The next implementation step should not be more ad hoc fixes inside `TestViewModel`.

It should be a runtime rewrite around the TCA-inspired buffered root send loop, adapted deliberately to Lattice's async-native execution model.

Once that is in place:
- `TestViewModel` becomes simpler;
- `EventTask` and `TestEventTask` stay thin;
- deterministic `send`/`receive` boundaries become a runtime property rather than a test-layer approximation;
- cancellation can move into the `Emission` model where it belongs.
