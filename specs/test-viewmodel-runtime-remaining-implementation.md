# TestViewModel Runtime Remaining Implementation Plan

Status: proposed implementation plan for the items still marked `partial` or `todo` in [test-viewmodel-runtime-implementation-status.md](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-implementation-status.md).

Related:
- [TestViewModel Runtime Alignment with TCA Themes](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-runtime-tca-alignment.md)
- [TestViewModel: Feature-First Testing Runtime](/Users/michaelbattaglia/Documents/lattice/lattice/specs/test-viewmodel-testing-runtime.md)

## Scope

This document covers only the work that remains open in the current status checklist:

1. buffered root send loop;
2. reentrant user-send guard;
3. local-state reduction wave with one state commit;
4. deterministic runtime synchronization for test sends and receives;
5. `.append` sequencing by direct child completion;
6. emission-owned cancellation identities;
7. non-exhaustive `receive` matching later buffered items;
8. presentation relevance centralized in the runtime;
9. `skipInFlightEffects` semantics clarified;
10. test coverage updated to validate the new runtime shape.

It does not restate the already-completed runtime/test facade work.

## Current Code Surface

Primary files implicated by the remaining work:

- [Sources/Lattice/Internal/FeatureRuntime.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/FeatureRuntime.swift)
- [Sources/Lattice/Internal/EffectTaskRegistry.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Internal/EffectTaskRegistry.swift)
- [Sources/Lattice/Domain/Emission.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Domain/Emission.swift)
- [Sources/Lattice/Presentation/ViewModel/ViewModel.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Presentation/ViewModel/ViewModel.swift)
- [Sources/Lattice/Testing/TestViewModel.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Sources/Lattice/Testing/TestViewModel.swift)
- [Tests/LatticeTests/TestingInfrastructureTests/TestViewModelTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/TestingInfrastructureTests/TestViewModelTests.swift)

## Decisions And Ambiguities

These points should be decided explicitly before implementation starts. The plan below calls them out rather than silently assuming the most convenient answer.

### Ambiguity 1: what does "observe startup is deterministic" mean with a synchronous `send` API?

The alignment spec says `send` should not return until `.observe` subscriptions have started. The current public production API is synchronous:

```swift
@discardableResult
public func sendViewEvent(_ event: Action) -> EventTask
```

`FeatureRuntime.send` is also synchronous today. That means the runtime cannot literally `await stream()` before returning without a breaking API change or a blocking bridge.

The current `onStep` callback is synchronous, so the sent-step snapshot itself is already available by the time `runtime.send(action)` returns. The real ambiguity is the startup boundary for async emissions spawned by that step.

Two viable options:

1. Narrow the guarantee:
   Guarantee that the observation task is registered before `send` returns, and expose an internal async startup waiter that `TestViewModel.send` can await.

2. Change the model:
   Make `.observe` startup synchronously construct the stream, or make runtime send itself async.

Recommendation:
Choose option 1. It preserves the current public API and still removes `Task.yield()` from tests.

Concretely:

- keep `FeatureRuntime.send` synchronous;
- keep `ViewModel.sendViewEvent(_:)` synchronous;
- add an internal async startup waiter that `TestViewModel.send` can await before returning.

### Ambiguity 2: how hard should reentrant user sends fail?

TCA currently reports an issue for reentrant store-origin sends and is trending toward stricter failure. Lattice does not currently have an issue-reporting layer in this path.

Two viable options:

1. `assertionFailure` in debug, buffer the action, continue.
2. `preconditionFailure` in debug and release.

Recommendation:
Start with `assertionFailure` in debug plus buffering. It tightens behavior without turning this rewrite into a public behavior break.

### Ambiguity 3: should `skipInFlightEffects` remain destructive?

The status file correctly identifies that the current implementation cancels underlying work:

```swift
taskRegistry.cancelAll()
let result = await runtime.finish(timeout: defaultTimeout)
```

That is not the same as TCA's bookkeeping-oriented skipping.

Two viable options:

1. Preserve destructive cancellation, but rename the API.
2. Preserve the name, change semantics to bookkeeping-only skipping.

Recommendation:
Prefer option 1 for this implementation pass:

```diff
- public func skipInFlightEffects(...)
+ public func cancelInFlightEffects(...)
```

If source compatibility must be preserved, keep `skipInFlightEffects` as a deprecated forwarding shim with documentation that it cancels work.

## Recommended Implementation Order

1. Rewrite `FeatureRuntime.send` around a buffered root loop.
2. Introduce runtime-owned startup wait channels and facade-owned received-step wait channels.
3. Rework `.append` to sequence on direct child completion handles.
4. Centralize presentation relevance in `FeatureRuntime`.
5. Extend `Emission` with cancellation identities.
6. Finalize the non-exhaustive `receive` and `cancel/skip in-flight` behavior.
7. Update and expand tests.

The ordering matters. The test-runtime cleanup should not land before the runtime exposes stable boundaries to wait on.

## Phase 1: Buffered Root Send Loop

### Goal

Make `FeatureRuntime` process one buffered send wave at a time, reduce into a local `currentState`, and commit the final state once per root wave.

### Why

This removes the recursive send shape that currently forces `TestViewModel` to compensate with `Task.yield()`. It also makes synchronous `.action` emissions behave predictably under nested waves.

### Proposed runtime shape

```swift
@MainActor
final class FeatureRuntime<State: Sendable, Action: Sendable> {
    enum ActionSource: Sendable {
        case sent
        case emitted
    }

    struct Step: Sendable {
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

    private var bufferedActions: [(action: Action, source: ActionSource, originID: UUID)] = []
    private var isSending = false
}
```

### Concrete diff

```diff
diff --git a/Sources/Lattice/Internal/FeatureRuntime.swift b/Sources/Lattice/Internal/FeatureRuntime.swift
@@
     struct RuntimeSendResult: Sendable {
         let originID: UUID
-        let step: Step
         let startedEmissionCount: Int
     }
@@
+    private var bufferedActions: [(action: Action, source: ActionSource, originID: UUID)] = []
+    private var isSending = false
@@
     func send(
         _ action: Action,
         source: ActionSource = .sent,
         originID: UUID? = nil
     ) -> RuntimeSendResult {
         let resolvedOriginID = originID ?? UUID()
-        let previousState = state
-        let emission = interactor.interact(state: &state, action: action)
-
-        let step = Step(
-            action: action,
-            source: source,
-            previousState: previousState,
-            currentState: state,
-            originID: resolvedOriginID
-        )
-        onStep?(step)
-
-        let startedEmissionCount = spawnTasks(
-            from: emission,
-            originID: resolvedOriginID
-        )
+        bufferedActions.append((action, source, resolvedOriginID))
+        guard !isSending else {
+            if case .sent = source {
+                assertionFailure("Reentrant user-origin sends are not supported.")
+            }
+            return RuntimeSendResult(
+                originID: resolvedOriginID,
+                startedEmissionCount: 0
+            )
+        }
+
+        isSending = true
+        var currentState = state
+        var totalStartedEmissionCount = 0
+        defer {
+            bufferedActions.removeAll()
+            state = currentState
+            isSending = false
+        }
+
+        var index = bufferedActions.startIndex
+        while index < bufferedActions.endIndex {
+            let buffered = bufferedActions[index]
+            let previousState = currentState
+            let emission = interactor.interact(state: &currentState, action: buffered.action)
+
+            let step = Step(
+                action: buffered.action,
+                source: buffered.source,
+                previousState: previousState,
+                currentState: currentState,
+                originID: buffered.originID
+            )
+            onStep?(step)
+            totalStartedEmissionCount += spawnTasks(
+                from: emission,
+                originID: buffered.originID
+            )
+            index += 1
+        }
 
         return RuntimeSendResult(
             originID: resolvedOriginID,
-            step: step,
-            startedEmissionCount: startedEmissionCount
+            startedEmissionCount: totalStartedEmissionCount
         )
     }
```

### Notes

- Removing `RuntimeSendResult.step` is intentional. Once one root send can produce multiple synchronous steps, a single stored step is misleading.
- `spawnTasks(from:originID:)` can still call `send(..., source: .emitted, originID: ...)`; those actions will be buffered into the same wave instead of recursively mutating `state`.

### Tests to add

- A send that returns `.action(.child)` should produce two ordered `Step`s but one final state commit.
- A nested `.action` wave should not require `Task.yield()` for `TestViewModel.send` to observe the sent snapshot.
- A user-origin reentrant send should trip the debug assertion path.

## Phase 2: Runtime Synchronization Channels

### Goal

Replace test-layer polling with explicit runtime/facade synchronization.

### Why

The current test runtime has two ad hoc waits:

```swift
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

Those should be replaced by continuations driven by actual runtime events.

The important split is:

- runtime-owned waiting for the async startup boundary of a send;
- `TestViewModel`-owned waiting for future buffered received steps.

### Proposed additions

Keep the sent-step path simple:

- `pendingSentSnapshots` is already filled synchronously from `handle(step:)`;
- after phase 1, `runtime.send(action)` returning is enough to read the sent snapshot;
- only async emission startup still needs an awaited boundary.

Add internal waiters to `TestViewModel` only for received steps:

```swift
private var receivedStepWaiters: [CheckedContinuation<Void, Never>] = []
```

Add helper methods:

```swift
private func waitForReceivedStep(timeout: Duration) async -> ReceivedStep?
private func resumeReceivedStepWaiters()
```

### Concrete diff

```diff
diff --git a/Sources/Lattice/Testing/TestViewModel.swift b/Sources/Lattice/Testing/TestViewModel.swift
@@
+    private var receivedStepWaiters: [CheckedContinuation<Void, Never>] = []
@@
         let result = runtime.send(action)
+        if let startupToken = result.startupToken {
+            let didStart = await runtime.waitForStartup(
+                of: startupToken,
+                timeout: defaultTimeout
+            )
+            if !didStart {
+                reportFailure(...)
+                return makeTestEventTask(originID: result.originID)
+            }
+        }
@@
     private func nextReceivedStep(timeout: Duration) async -> ReceivedStep? {
         if let firstStep = bufferedReceivedSteps.first {
             return firstStep
         }
-
-        let clock = ContinuousClock()
-        let deadline = clock.now + timeout
-
-        while bufferedReceivedSteps.isEmpty {
-            guard clock.now < deadline else { return nil }
-            await Task.yield()
-        }
-
-        return bufferedReceivedSteps.first
+        return await waitForReceivedStep(timeout: timeout)
     }
@@
         switch step.source {
         case .sent:
             pendingSentSnapshots[step.originID] = SentStepSnapshot(
                 domainState: step.currentState,
                 viewState: nextViewState,
                 previousState: step.previousState
             )
 
         case .emitted:
             bufferedReceivedSteps.append(
                 ReceivedStep(
                     action: step.action,
                     domainState: step.currentState,
                     viewState: nextViewState,
                     originID: step.originID
                 )
             )
+            resumeReceivedStepWaiters()
         }
     }
```

### Suggested helper implementation

```swift
private func waitForReceivedStep(timeout: Duration) async -> ReceivedStep? {
    if let first = bufferedReceivedSteps.first {
        return first
    }

    let didReceiveStep = await withTaskGroup(of: Bool.self) { group in
        group.addTask { @MainActor [weak self] in
            guard let self else { return false }
            await withCheckedContinuation { continuation in
                self.receivedStepWaiters.append(continuation)
            }
            return true
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }

        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }

    guard didReceiveStep else { return nil }
    return bufferedReceivedSteps.first
}
```

The runtime event should drive the wakeup. The exact timeout wrapper can vary, but polling should be removed entirely.

### Important clarification

This phase does not require `FeatureRuntime.send` itself to become async. The async waiting remains in `TestViewModel.send` and `receive`, which are already async.

It also does not require a sent-step continuation unless `onStep` delivery is later made asynchronous. With the current code, the sent snapshot is already synchronous; the unstable boundary is async emission startup, not sent-step visibility.

## Phase 3: Deterministic Async Registration

### Goal

Give the runtime an explicit notion of "startup registered" so tests can wait on a real boundary instead of yield heuristics.

### Recommended interpretation

Because the production send path is synchronous, the practical guarantee should be:

- `.perform`: task creation and task registry insertion are complete before `send` returns;
- `.observe`: observation task creation and task registry insertion are complete before `send` returns;
- `.append`: the coordinator task is registered before `send` returns;
- `.merge`: all immediate children are registered before `send` returns.

If tests need stronger guarantees for `.observe`, add an internal async startup waiter on the runtime rather than redefining `send` as synchronous-and-fully-started.

### Concrete addition

```swift
struct RuntimeSendResult: Sendable {
    let originID: UUID
    let startedEmissionCount: Int
    let startupToken: UUID?
}

func waitForStartup(of token: UUID, timeout: Duration?) async -> Bool
```

### Why this shape

`TestViewModel.send` can await runtime startup when needed, but `ViewModel.sendViewEvent` can remain synchronous. That preserves API stability.

### Suggested runtime bookkeeping

```swift
private var startupWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
private var pendingStartupCounts: [UUID: Int] = [:]
private var completedStartupTokens: Set<UUID> = []
```

A root send creates one startup token only when at least one async emission requires startup tracking. Immediate `.action` and `.none` do not need one.

### Suggested runtime shape

```swift
private func registerPendingStartup(for token: UUID) {
    pendingStartupCounts[token, default: 0] += 1
}

private func markStartupComplete(for token: UUID) {
    guard let count = pendingStartupCounts[token] else { return }

    if count > 1 {
        pendingStartupCounts[token] = count - 1
        return
    }

    pendingStartupCounts[token] = nil
    completedStartupTokens.insert(token)
    let waiters = startupWaiters[token] ?? []
    startupWaiters[token] = nil
    waiters.forEach { $0.resume() }
}
```

Use it like this:

- `.perform`: task insertion into the registry satisfies the startup boundary immediately;
- `.observe`: call `registerPendingStartup(for:)` before launching the task, then `markStartupComplete(for:)` after the stream has been obtained and the observation loop is ready to consume it;
- `.merge`: each child contributes startup work independently;
- `.append`: only the coordinator task participates in the immediate startup boundary.

### Ambiguity carried forward

If the team wants "`await stream()` has completed" semantics for `.observe`, this should be encoded as:

```swift
func waitForObservationStartup(originID: UUID, timeout: Duration?) async -> Bool
```

That is stronger than task registration and should remain test-only/internal unless the public API is widened.

## Phase 4: `.append` By Direct Child Completion

### Goal

Stop using origin-wide in-flight counts as the sequencing primitive for appended emissions.

### Why

The current implementation:

```swift
_ = self.spawnTasks(from: emission, originID: originID)
await self.waitForOriginEmissionCount(originID, targetCount: 1)
```

works only because the coordinator assumes the origin-wide count will eventually collapse back to a magic number. That is fragile once the origin has unrelated concurrent emissions.

### Proposed internal handle

```swift
private struct EmissionHandle: Sendable {
    let startedEmissionCount: Int
    let finish: @Sendable () async -> Void
}
```

Add an internal runtime method:

```swift
private func startEmission(
    from emission: Emission<Action>,
    originID: UUID
) -> EmissionHandle
```

### Concrete diff

```diff
diff --git a/Sources/Lattice/Internal/FeatureRuntime.swift b/Sources/Lattice/Internal/FeatureRuntime.swift
@@
-    private func spawnTasks(
-        from emission: Emission<Action>,
-        originID: UUID
-    ) -> Int {
+    private func startEmission(
+        from emission: Emission<Action>,
+        originID: UUID
+    ) -> EmissionHandle {
         switch emission.kind {
         case .none:
-            return 0
+            return EmissionHandle(startedEmissionCount: 0, finish: {})
 
         case .action(let action):
-            return send(
-                action,
-                source: .emitted,
-                originID: originID
-            ).startedEmissionCount
+            let result = send(action, source: .emitted, originID: originID)
+            return EmissionHandle(
+                startedEmissionCount: result.startedEmissionCount,
+                finish: {}
+            )
@@
         case .merge(let emissions):
-            return emissions.reduce(into: 0) { count, childEmission in
-                count += spawnTasks(from: childEmission, originID: originID)
-            }
+            let children = emissions.map { startEmission(from: $0, originID: originID) }
+            return EmissionHandle(
+                startedEmissionCount: children.reduce(0) { $0 + $1.startedEmissionCount },
+                finish: {
+                    for child in children {
+                        await child.finish()
+                    }
+                }
+            )
 
         case .append(let emissions):
             guard !emissions.isEmpty else {
-                return 0
+                return EmissionHandle(startedEmissionCount: 0, finish: {})
             }
 
             let taskID = registerTrackedEmission(originID: originID)
             let task = Task { @MainActor [weak self] in
                 guard let self else { return }
 
                 for emission in emissions {
                     guard !Task.isCancelled else {
                         self.finishTrackedEmission(originID: originID, taskID: taskID)
                         return
                     }
 
-                    _ = self.spawnTasks(from: emission, originID: originID)
-                    await self.waitForOriginEmissionCount(originID, targetCount: 1)
+                    let child = self.startEmission(from: emission, originID: originID)
+                    await child.finish()
                 }
 
                 self.finishTrackedEmission(originID: originID, taskID: taskID)
             }
             taskRegistry.insert(task: task, taskID: taskID, originID: originID)
-            return 1
+            return EmissionHandle(
+                startedEmissionCount: 1,
+                finish: { await task.value }
+            )
         }
     }
```

### Notes

- Once `startEmission` exists, `send` should accumulate `startedEmissionCount` via `startEmission(...).startedEmissionCount`.
- `finish(originID:)` can continue to use origin bookkeeping for the public task handle; the sequencing primitive for `.append` is what changes here.

## Phase 5: Presentation Relevance Helper

### Goal

Remove duplicated "should this step reduce view state?" logic from `ViewModel` and `TestViewModel`.

### Why

Both facades currently embed this rule inline:

```swift
step.source == .emitted || !areStatesEqual(step.previousState, step.currentState)
```

That is already a drift point.

### Concrete diff

```diff
diff --git a/Sources/Lattice/Internal/FeatureRuntime.swift b/Sources/Lattice/Internal/FeatureRuntime.swift
@@
+    func shouldReducePresentation(
+        for step: Step,
+        areStatesEqual: @Sendable (State, State) -> Bool
+    ) -> Bool {
+        step.source == .emitted || !areStatesEqual(step.previousState, step.currentState)
+    }
diff --git a/Sources/Lattice/Presentation/ViewModel/ViewModel.swift b/Sources/Lattice/Presentation/ViewModel/ViewModel.swift
@@
-            let shouldReduceViewState =
-                step.source == .emitted || !self.areStatesEqual(step.previousState, step.currentState)
-
-            guard shouldReduceViewState else { return }
+            guard runtime.shouldReducePresentation(for: step, areStatesEqual: self.areStatesEqual)
+            else { return }
             self.viewStateReducer.reduce(step.currentState, into: &self.viewState)
diff --git a/Sources/Lattice/Testing/TestViewModel.swift b/Sources/Lattice/Testing/TestViewModel.swift
@@
-        let shouldReduceViewState =
-            step.source == .emitted || !areStatesEqual(step.previousState, step.currentState)
-
-        if shouldReduceViewState {
+        if runtime.shouldReducePresentation(for: step, areStatesEqual: areStatesEqual) {
             viewStateReducer.reduce(step.currentState, into: &nextViewState)
         }
```

### Result

Future runtime source-kind changes update one helper instead of two facade implementations.

## Phase 6: Cancellation Identities On `Emission`

### Goal

Move cancellation ownership into the emission model so interactors can express replacement and teardown directly.

### Why

Right now cancellation is predominantly caller-owned through `EventTask` and `TestEventTask`. That is not sufficient for long-lived observation and replace-in-flight behavior.

### Proposed API

```swift
public struct Emission<Action: Sendable>: Sendable {
    public struct CancellationIdentity: Sendable, Hashable {
        public let rawValue: AnyHashable

        public init(_ rawValue: some Hashable & Sendable) {
            self.rawValue = AnyHashable(rawValue)
        }
    }

    public enum Kind: Sendable {
        case none
        case action(Action)
        case perform(
            work: @Sendable () async -> Action?,
            cancellation: CancellationIdentity?,
            cancelInFlight: Bool
        )
        case observe(
            stream: @Sendable () async -> AsyncStream<Action>,
            cancellation: CancellationIdentity?,
            cancelInFlight: Bool
        )
        case merge([Emission<Action>])
        case append([Emission<Action>])
        case cancel(CancellationIdentity)
    }
}
```

Convenience API:

```swift
extension Emission {
    public func cancellable(
        id: some Hashable & Sendable,
        cancelInFlight: Bool = false
    ) -> Self

    public static func cancel(
        id: some Hashable & Sendable
    ) -> Self
}
```

### Runtime support

Augment the task registry with cancellation-identity bookkeeping:

```swift
final class EffectTaskRegistry: @unchecked Sendable {
    func insert(
        task: Task<Void, Never>,
        taskID: UUID,
        originID: UUID,
        cancellationID: AnyHashable?
    )

    func cancel(cancellationID: AnyHashable)
}
```

Because `EffectTaskRegistry` is not generic today, the concrete implementation should store `AnyHashable`-backed IDs rather than generic emission types.

If Swift 6 sendability rejects `AnyHashable` in this position on the supported toolchains, use a dedicated wrapper or `UncheckedSendable<AnyHashable>` internally rather than weakening the API surface with broader unchecked sendability.

### Concrete runtime behavior

- if a new emission is marked `.cancellable(id: x, cancelInFlight: true)`, cancel existing tasks with `x` before inserting the new task;
- if `.cancel(id: x)` is emitted, cancel all in-flight tasks with `x` and do not start new work;
- `.append` and `.merge` should preserve child cancellation metadata rather than stripping it.

### Ambiguity

The current public debounce API may already model some replacement semantics separately. That should be reviewed before duplicating behavior. If debouncing remains layered on top, it should compose with cancellation IDs rather than compete with them.

## Phase 7: `TestViewModel.receive` In Non-Exhaustive Mode

### Goal

Let non-exhaustive `receive` match a later buffered action while skipping earlier ones.

### Why

The status file is correct: current `receive` only checks the first buffered action.

### Proposed behavior

- exhaustive mode:
  only the first buffered action may be matched;
- non-exhaustive mode:
  search `bufferedReceivedSteps` for the first matching action;
- if earlier actions are skipped in non-exhaustive mode:
  advance `domainState` and `viewState` through their snapshots before asserting the matched step;
- if `showSkippedAssertions` is enabled:
  report the skipped actions.

### Concrete diff

```diff
diff --git a/Sources/Lattice/Testing/TestViewModel.swift b/Sources/Lattice/Testing/TestViewModel.swift
@@
-        guard let receivedStep = await nextReceivedStep(timeout: timeout ?? defaultTimeout) else {
+        guard let match = await nextReceivedStep(
+            matching: isMatching,
+            timeout: timeout ?? defaultTimeout
+        ) else {
             reportFailure(...)
             return
         }
@@
-        guard isMatching(receivedStep.action) else {
-            reportFailure(...)
-            return
-        }
-
-        bufferedReceivedSteps.removeFirst()
-        assertStateChange(
-            from: domainState,
-            to: receivedStep.domainState,
+        if !match.skippedSteps.isEmpty, shouldShowSkippedAssertions {
+            reportFailure(...)
+        }
+
+        if let lastSkipped = match.skippedSteps.last {
+            domainState = lastSkipped.domainState
+            viewState = lastSkipped.viewState
+        }
+
+        bufferedReceivedSteps.removeFirst(match.consumedCount)
+        assertStateChange(
+            from: domainState,
+            to: match.step.domainState,
             updateExpectedState: updateExpectedState,
             ...
         )
 
-        domainState = receivedStep.domainState
-        viewState = receivedStep.viewState
+        domainState = match.step.domainState
+        viewState = match.step.viewState
         refreshBufferedViewState()
```

### Suggested helper result

```swift
private struct ReceivedStepMatch {
    let step: ReceivedStep
    let skippedSteps: [ReceivedStep]
    let consumedCount: Int
}
```

## Phase 8: Rename Or Redefine `skipInFlightEffects`

### Goal

Make the API name match the actual behavior.

### Recommended implementation

Preserve current destructive behavior, but rename it:

```diff
diff --git a/Sources/Lattice/Testing/TestViewModel.swift b/Sources/Lattice/Testing/TestViewModel.swift
@@
-    public func skipInFlightEffects(
+    public func cancelInFlightEffects(
         strict: Bool = true,
         ...
     ) async {
         guard runtime.hasInFlightEmissions() else { ... }
 
         taskRegistry.cancelAll()
         let result = await runtime.finish(timeout: defaultTimeout)
@@
     }
+
+    @available(*, deprecated, renamed: "cancelInFlightEffects(strict:fileID:file:line:column:)")
+    public func skipInFlightEffects(
+        strict: Bool = true,
+        fileID: StaticString = #fileID,
+        file: StaticString = #filePath,
+        line: UInt = #line,
+        column: UInt = #column
+    ) async {
+        await cancelInFlightEffects(
+            strict: strict,
+            fileID: fileID,
+            file: file,
+            line: line,
+            column: column
+        )
+    }
```

### Why this recommendation

It is the smallest behaviorally honest change. A bookkeeping-only reinterpretation would require new runtime state for "ignored in-flight work" and should not be mixed into the same rewrite unless TCA parity is the overriding goal.

## Phase 9: Test Additions

Add or update tests in [Tests/LatticeTests/TestingInfrastructureTests/TestViewModelTests.swift](/Users/michaelbattaglia/Documents/lattice/lattice/Tests/LatticeTests/TestingInfrastructureTests/TestViewModelTests.swift) and runtime-adjacent test files.

### Tests to add

1. buffered root loop processes `.action` emissions in-order without recursive state commits.
2. `TestViewModel.send` no longer needs `Task.yield()` to observe the sent snapshot.
3. `receive` wakes from a continuation, not a polling loop.
4. `.append` sequencing remains ordered even when another origin-scoped emission stays in flight.
5. non-exhaustive `receive` can match the second buffered action and skip the first.
6. `cancelInFlightEffects` cancels work and drains the runtime.
7. presentation reduction is identical between `ViewModel` and `TestViewModel` for the same runtime step sequence.

### Suggested new targeted test for `.append`

```swift
@Test
func appendDoesNotDependOnGlobalOriginCount() async {
    let feature = Feature(interactor: AppendWithConcurrentObservationInteractor())
    let model = TestViewModel(
        initialDomainState: AppendState(),
        feature: feature
    )

    await model.send(.start)

    await model.receive(.logged("first")) {
        $0.log = ["first"]
    }

    await model.receive(.logged("second")) {
        $0.log = ["first", "second"]
    }
}
```

The interactor should intentionally keep an unrelated observation alive so the old origin-count heuristic would be vulnerable.

## Summary Of Expected File Changes

### `Sources/Lattice/Internal/FeatureRuntime.swift`

- add `bufferedActions` and `isSending`;
- rewrite `send` around a local reduction wave;
- remove `RuntimeSendResult.step`;
- add internal emission handles or equivalent for `.append`;
- add a shared `shouldReducePresentation` helper;
- add internal startup/wait bookkeeping only if tests need a stronger startup boundary.

### `Sources/Lattice/Testing/TestViewModel.swift`

- remove `Task.yield()` from `send`;
- replace `nextReceivedStep` polling with continuation-based waiting;
- add non-exhaustive later-match behavior for `receive`;
- rename or deprecate `skipInFlightEffects` in favor of `cancelInFlightEffects`;
- continue buffering received steps as the authoritative receive queue.

### `Sources/Lattice/Domain/Emission.swift`

- add cancellation identity support;
- add `.cancel(id:)`;
- add `.cancellable(id:cancelInFlight:)` sugar.

### `Sources/Lattice/Internal/EffectTaskRegistry.swift`

- add cancellation-identity indexing alongside origin indexing;
- preserve current origin-based APIs for `EventTask` and `TestEventTask`.

### `Sources/Lattice/Presentation/ViewModel/ViewModel.swift`

- route presentation relevance through the runtime helper.

## Acceptance Criteria

The implementation is done when all of the following are true:

- `FeatureRuntime.send` no longer recursively mutates `state`.
- a synchronous `.action` chain is processed within one buffered root wave.
- `TestViewModel.send` and `receive` no longer use `Task.yield()`.
- `.append` ordering does not depend on origin-wide emission counts.
- `Emission` can express cancellation ownership directly.
- `TestViewModel.receive` can skip earlier buffered actions in non-exhaustive mode.
- the production and test facades share the same presentation-relevance rule.
- the in-flight skipping/cancellation API is named consistently with its semantics.
