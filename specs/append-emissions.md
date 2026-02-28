# Append Emissions

Goal: keep Lattice naming (`append` / `then`) while aligning behavior and composition approach with TCA's sequential effect composition (`concatenate`).

## Core Direction

1. `.merge` remains the concurrent composition primitive.
2. `.append` is the sequential composition primitive.
3. `.then` is fluent sugar over `.append`.
4. Implement sequencing as an additive composition behavior, not a broad runtime rewrite.

---

## Phase 1: Emission Domain Layer

### 1a. Add `.append` case to `Emission.Kind`

**File:** `Sources/Lattice/Domain/Emission.swift`
**Location:** Lines 86–91 (after `.merge`)

```diff
         /// Used by higher-order interactors like ``Interactors/Merge`` to combine
         /// the emissions from multiple child interactors.
         case merge([Emission<Action>])
+
+        /// Compose emissions sequentially.
+        ///
+        /// Each emission completes before the next one starts.
+        /// Used with `.then` for fluent chaining.
+        case append([Emission<Action>])
     }
```

### 1b. Add static `.append` APIs and fluent `.then`

**File:** `Sources/Lattice/Domain/Emission.swift`
**Location:** After `.merging(with:)` (line 171), before the closing `}`

```diff
     public func merging(with other: Emission<Action>) -> Emission<Action> {
         .merge([self, other])
     }
+
+    /// Compose emissions to run sequentially.
+    ///
+    /// Each emission completes before the next one starts.
+    /// Nested `.append` children are flattened, `.none` children are dropped,
+    /// and single-child results are unwrapped.
+    ///
+    /// - Parameter emissions: The emissions to run in order.
+    /// - Returns: A sequentially composed emission.
+    public static func append(_ emissions: Emission<Action>...) -> Emission {
+        append(emissions)
+    }
+
+    /// Compose a collection of emissions to run sequentially.
+    ///
+    /// - Parameter emissions: The emissions to run in order.
+    /// - Returns: A sequentially composed emission.
+    public static func append(_ emissions: some Collection<Emission<Action>>) -> Emission {
+        let normalized = emissions
+            .flatMap { emission -> [Emission<Action>] in
+                switch emission.kind {
+                case .append(let nested):
+                    return nested
+                case .none:
+                    return []
+                default:
+                    return [emission]
+                }
+            }
+
+        switch normalized.count {
+        case 0: return .none
+        case 1: return normalized[0]
+        default: return Emission(kind: .append(normalized))
+        }
+    }
+
+    /// Returns a new emission that runs this emission followed by another.
+    ///
+    /// - Parameter other: The emission to run after this one completes.
+    /// - Returns: A sequentially composed emission.
+    public func appending(with other: Emission<Action>) -> Emission<Action> {
+        .append(self, other)
+    }
+
+    /// Returns a new emission that runs this emission followed by another.
+    ///
+    /// Sugar for ``appending(with:)``.
+    ///
+    /// - Parameter next: The emission to run after this one completes.
+    /// - Returns: A sequentially composed emission.
+    public func then(_ next: @escaping () -> Emission<Action>) -> Emission<Action> {
+        appending(with: next())
+    }
 }
```

### 1c. Update `.map` for `.append`

**File:** `Sources/Lattice/Domain/Emission.swift`
**Location:** Inside `map(_:)`, after the `.merge` case (line 218)

```diff
         case .merge(let emissions):
             return .merge(emissions.map { $0.map(transform) })
+
+        case .append(let emissions):
+            return .append(emissions.map { $0.map(transform) })
         }
```

### 1d. Update `.debounce` for `.append`

**File:** `Sources/Lattice/Domain/Emission+Debounce.swift`
**Location:** After the `.merge` case (line 56), before the closing `}`

```diff
         case .merge(let emissions):
             return .merge(emissions.map { $0.debounce(using: debouncer) })
+
+        case .append(let emissions):
+            return .append(emissions.map { $0.debounce(using: debouncer) })
         }
```

---

## Phase 2: Runtime — `.append` in `spawnTasks`

Handle `.append` directly inside the existing `spawnTasks` switch in both `ViewModel` and `InteractorTestHarness`. No new files, no engine abstraction — just a new case that spawns a single `Task` which loops through children sequentially.

The pattern: for each child emission, call `spawnTasks` to get its tasks, register them in `effectTasks`, await all of them via a task group, clean up UUIDs, then move to the next child. Canceling the outer task stops the loop and cancels whatever is currently running.

### 2a. Add `.append` case in `ViewModel.spawnTasks`

**File:** `Sources/Lattice/Presentation/ViewModel/ViewModel.swift`
**Location:** After the `.merge` case (line 266–270), before the closing `}`

```diff
         case .merge(let emissions):
             return emissions.reduce(into: [:]) { result, emission in
                 result.merge(spawnTasks(from: emission)) { _, new in new }
             }
+
+        case .append(let emissions):
+            guard !emissions.isEmpty else { return [:] }
+            let uuid = UUID()
+            let task = Task {[weak self] in
+                for emission in emissions {
+                    guard !Task.isCancelled, let self else { return }
+                    let childTasks = self.spawnTasks(from: emission)
+                    guard !childTasks.isEmpty else { continue }
+
+                    let childUUIDs = Set(childTasks.keys)
+                    self.effectTasks.merge(childTasks) { _, new in new }
+
+                    let childList = Array(childTasks.values)
+                    await withTaskCancellationHandler {
+                        await withTaskGroup(of: Void.self) { group in
+                            for task in childList {
+                                group.addTask { await task.value }
+                            }
+                        }
+                    } onCancel: {
+                        for task in childList { task.cancel() }
+                    }
+                    for id in childUUIDs { self.effectTasks[id] = nil }
+                }
+            }
+            return [uuid: task]
         }
```

### 2b. Add `.append` case in `InteractorTestHarness.spawnTasks`

**File:** `Sources/Lattice/Testing/InteractorTestHarness.swift`
**Location:** After the `.merge` case (line 195–199), before the closing `}`

```diff
         case .merge(let emissions):
             return emissions.reduce(into: [:]) { result, emission in
                 result.merge(spawnTasks(from: emission)) { _, new in new }
             }
+
+        case .append(let emissions):
+            guard !emissions.isEmpty else { return [:] }
+            let uuid = UUID()
+            let task = Task { @MainActor [weak self] in
+                for emission in emissions {
+                    guard !Task.isCancelled, let self else { return }
+                    let childTasks = self.spawnTasks(from: emission)
+                    guard !childTasks.isEmpty else { continue }
+
+                    let childUUIDs = Set(childTasks.keys)
+                    self.effectTasks.merge(childTasks) { _, new in new }
+
+                    let childList = Array(childTasks.values)
+                    await withTaskCancellationHandler {
+                        await withTaskGroup(of: Void.self) { group in
+                            for task in childList {
+                                group.addTask { await task.value }
+                            }
+                        }
+                    } onCancel: {
+                        for task in childList { task.cancel() }
+                    }
+                    for id in childUUIDs { self.effectTasks[id] = nil }
+                }
+            }
+            return [uuid: task]
         }
```

---

## Phase 3: Tests

### 3a. EmissionAppendTests (normalization)

**New file:** `Tests/LatticeTests/DomainTests/EmissionAppendTests.swift`

```swift
import Testing

@testable import Lattice

@Suite
@MainActor
struct EmissionAppendTests {

    enum Action: Sendable, Equatable {
        case a, b, c
    }

    @Test
    func flattenNestedAppend() {
        let inner = Emission<Action>.append(
            .action(.a),
            .action(.b)
        )
        let outer = Emission<Action>.append(inner, .action(.c))

        guard case .append(let children) = outer.kind else {
            Issue.record("Expected .append")
            return
        }

        #expect(children.count == 3)
        guard case .action(.a) = children[0].kind,
              case .action(.b) = children[1].kind,
              case .action(.c) = children[2].kind
        else {
            Issue.record("Expected flattened [.a, .b, .c]")
            return
        }
    }

    @Test
    func dropsNoneChildren() {
        let emission = Emission<Action>.append(.none, .action(.a), .none)

        guard case .action(.a) = emission.kind else {
            Issue.record("Expected single .action(.a) after dropping .none")
            return
        }
    }

    @Test
    func emptyAppendIsNone() {
        let emission = Emission<Action>.append([Emission<Action>]())

        guard case .none = emission.kind else {
            Issue.record("Expected .none for empty append")
            return
        }
    }

    @Test
    func allNoneChildrenCollapseToNone() {
        let emission = Emission<Action>.append(.none, .none, .none)

        guard case .none = emission.kind else {
            Issue.record("Expected .none when all children are .none")
            return
        }
    }

    @Test
    func singleChildUnwrapped() {
        let emission = Emission<Action>.append(.action(.a))

        guard case .action(.a) = emission.kind else {
            Issue.record("Expected unwrapped .action(.a)")
            return
        }
    }

    @Test
    func thenProducesSameResultAsAppending() {
        let via_then = Emission<Action>.action(.a)
            .then(.action(.b))

        let via_appending = Emission<Action>.action(.a)
            .appending(with: .action(.b))

        guard case .append(let c1) = via_then.kind,
              case .append(let c2) = via_appending.kind
        else {
            Issue.record("Expected .append for both")
            return
        }

        #expect(c1.count == c2.count)
    }

    @Test
    func mapRecursivelyTransformsAppendChildren() {
        let emission = Emission<Int>.append(
            .action(1),
            .action(2)
        )

        let mapped = emission.map { String($0) }

        guard case .append(let children) = mapped.kind else {
            Issue.record("Expected .append")
            return
        }

        #expect(children.count == 2)
        guard case .action(let first) = children[0].kind,
              case .action(let second) = children[1].kind
        else {
            Issue.record("Expected .action children")
            return
        }
        #expect(first == "1")
        #expect(second == "2")
    }
}
```

### 3b. EmissionDebounceTests extension for `.append`

**File:** `Tests/LatticeTests/DomainTests/EmissionDebounceTests.swift`
**Location:** Add new test at the end of the suite (before the closing `}`)

```diff
+    @Test
+    func appendDebouncesPerformChildren() async throws {
+        let clock = TestClock()
+        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)
+
+        let perform1 = Emission<TestAction>.perform { .result(1) }
+        let perform2 = Emission<TestAction>.perform { .result(2) }
+        let appended = Emission<TestAction>.append(perform1, perform2).debounce(using: debouncer)
+
+        guard case .append(let emissions) = appended.kind else {
+            Issue.record("Expected .append emission")
+            return
+        }
+
+        #expect(emissions.count == 2)
+
+        guard case .perform(let work1) = emissions[0].kind,
+              case .perform(let work2) = emissions[1].kind
+        else {
+            Issue.record("Expected .perform emissions inside append")
+            return
+        }
+
+        async let r1 = work1()
+        async let r2 = work2()
+
+        await clock.advance(by: .milliseconds(300))
+
+        let results = await [r1, r2]
+
+        let nonNilCount = results.compactMap { $0 }.count
+        #expect(nonNilCount == 1, "Appended perform emissions share debouncer, so only one executes")
+    }
 }
```

### 3c. ViewModel sequential execution tests

**New file:** `Tests/LatticeTests/PresentationTests/ViewModelAppendTests.swift`

This test uses a dedicated interactor that returns `.append` emissions to verify ordering and completion.

```swift
import Foundation
import Testing

@testable import Lattice

@Suite(.serialized)
@MainActor
struct ViewModelAppendTests {

    struct State: Equatable, Sendable {
        var log: [String] = []
    }

    enum Action: Sendable, Equatable {
        case appendTwoPerforms
        case appendMergeThenPerform
        case appendPerformReturningNil
        case logged(String)
    }

    @Interactor<State, Action>
    struct AppendInteractor: Interactor {
        var body: some InteractorOf<Self> {
            Interact { state, action in
                switch action {
                case .appendTwoPerforms:
                    return .append(
                        .perform {
                            try? await Task.sleep(for: .milliseconds(10))
                            return .logged("first")
                        },
                        .perform {
                            try? await Task.sleep(for: .milliseconds(10))
                            return .logged("second")
                        }
                    )

                case .appendMergeThenPerform:
                    return .append(
                        .merge([
                            .perform { .logged("merge-a") },
                            .perform { .logged("merge-b") }
                        ]),
                        .perform { .logged("after-merge") }
                    )

                case .appendPerformReturningNil:
                    return .append(
                        .perform { nil },
                        .perform { .logged("after-nil") }
                    )

                case .logged(let entry):
                    state.log.append(entry)
                    return .none
                }
            }
        }
    }

    private func makeHarness() -> InteractorTestHarness<State, Action> {
        InteractorTestHarness(
            initialState: State(),
            interactor: AppendInteractor()
        )
    }

    @Test
    func appendedPerformsExecuteInOrder() async throws {
        let harness = makeHarness()

        await harness.send(.appendTwoPerforms).finish()

        #expect(harness.currentState.log == ["first", "second"])
    }

    @Test
    func appendWaitsForInnerMergeBeforeNext() async throws {
        let harness = makeHarness()

        await harness.send(.appendMergeThenPerform).finish()

        #expect(harness.currentState.log.contains("merge-a"))
        #expect(harness.currentState.log.contains("merge-b"))
        #expect(harness.currentState.log.last == "after-merge")
    }

    @Test
    func nilPerformDoesNotBlockNextStep() async throws {
        let harness = makeHarness()

        await harness.send(.appendPerformReturningNil).finish()

        #expect(harness.currentState.log == ["after-nil"])
    }

    @Test
    func cancelStopsRemainingAppendedSteps() async throws {
        let harness = makeHarness()

        let task = harness.send(.appendTwoPerforms)
        task.cancel()
        try? await Task.sleep(for: .milliseconds(50))

        // At most the first step ran; second should not have started
        #expect(harness.currentState.log.count <= 1)
    }

    @Test
    func finishAwaitsAllAppendedSteps() async throws {
        let harness = makeHarness()

        let task = harness.send(.appendTwoPerforms)
        #expect(task.hasEffects)

        await task.finish()
        #expect(harness.currentState.log.count == 2)
    }
}
```

### 3d. InteractorTestHarness append parity tests

**New file:** `Tests/LatticeTests/TestingInfrastructureTests/InteractorTestHarnessAppendTests.swift`

```swift
import Testing

@testable import Lattice

@Suite(.serialized)
@MainActor
struct InteractorTestHarnessAppendTests {

    struct State: Equatable, Sendable {
        var values: [Int] = []
    }

    enum Action: Sendable, Equatable {
        case runSequence
        case add(Int)
    }

    @Interactor<State, Action>
    struct SequenceInteractor: Interactor {
        var body: some InteractorOf<Self> {
            Interact { state, action in
                switch action {
                case .runSequence:
                    return .append(
                        .perform {
                            try? await Task.sleep(for: .milliseconds(5))
                            return .add(1)
                        },
                        .perform {
                            try? await Task.sleep(for: .milliseconds(5))
                            return .add(2)
                        },
                        .perform {
                            try? await Task.sleep(for: .milliseconds(5))
                            return .add(3)
                        }
                    )

                case .add(let value):
                    state.values.append(value)
                    return .none
                }
            }
        }
    }

    @Test
    func sendAndFinishMirrorsViewModelOrdering() async throws {
        let harness = InteractorTestHarness(
            initialState: State(),
            interactor: SequenceInteractor()
        )

        await harness.send(.runSequence).finish()

        #expect(harness.currentState.values == [1, 2, 3])
    }

    @Test
    func actionHistoryRecordsAllActions() async throws {
        let harness = InteractorTestHarness(
            initialState: State(),
            interactor: SequenceInteractor()
        )

        await harness.send(.runSequence).finish()

        try harness.assertActions([
            .runSequence,
            .add(1),
            .add(2),
            .add(3),
        ])
    }

    @Test
    func stateHistoryRecordsEachStep() async throws {
        let harness = InteractorTestHarness(
            initialState: State(),
            interactor: SequenceInteractor()
        )

        await harness.send(.runSequence).finish()

        try harness.assertStates([
            State(values: []),
            State(values: [1]),
            State(values: [1, 2]),
            State(values: [1, 2, 3]),
        ])
    }

    @Test
    func parentCancellationStopsRemainingSteps() async throws {
        let harness = InteractorTestHarness(
            initialState: State(),
            interactor: SequenceInteractor()
        )

        let task = harness.send(.runSequence)
        task.cancel()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(harness.currentState.values.count < 3)
    }
}
```

### 3e. Observe sequencing test

**New file:** `Tests/LatticeTests/DomainTests/EmissionAppendObserveTests.swift`

```swift
import Foundation
import Testing

@testable import Lattice

@Suite(.serialized)
@MainActor
struct EmissionAppendObserveTests {

    struct State: Equatable, Sendable {
        var log: [String] = []
    }

    enum Action: Sendable, Equatable {
        case startObserveThenPerform
        case logged(String)
    }

    @Interactor<State, Action>
    struct ObserveSequenceInteractor: Interactor {
        var body: some InteractorOf<Self> {
            Interact { state, action in
                switch action {
                case .startObserveThenPerform:
                    return .append(
                        .observe {
                            AsyncStream { continuation in
                                continuation.yield(.logged("stream-1"))
                                continuation.yield(.logged("stream-2"))
                                continuation.finish()
                            }
                        },
                        .perform { .logged("after-stream") }
                    )

                case .logged(let entry):
                    state.log.append(entry)
                    return .none
                }
            }
        }
    }

    @Test
    func finiteObserveCompletesBeforeNextStep() async throws {
        let harness = InteractorTestHarness(
            initialState: State(),
            interactor: ObserveSequenceInteractor()
        )

        await harness.send(.startObserveThenPerform).finish()

        #expect(harness.currentState.log == ["stream-1", "stream-2", "after-stream"])
    }
}
```

### 3f. Regression guardrail — merge remains concurrent

Add to `ViewModelAppendTests` or as a standalone check that `.merge` still runs concurrently (not sequentially). This is already covered by existing `Interactors+MergeTests`, but a focused check in the append context is valuable.

**Add to `ViewModelAppendTests.swift`:**

```swift
    @Test
    func mergeRemainsUnaffected() async throws {
        let harness = makeHarness()

        await harness.send(.appendMergeThenPerform).finish()

        // merge-a and merge-b both appear before after-merge
        let indexA = harness.currentState.log.firstIndex(of: "merge-a")!
        let indexB = harness.currentState.log.firstIndex(of: "merge-b")!
        let indexAfter = harness.currentState.log.firstIndex(of: "after-merge")!

        #expect(indexA < indexAfter)
        #expect(indexB < indexAfter)
    }
```

---

## Phase 4: Automated Verification

Run these commands in order after all changes are made. Each must pass before proceeding.

### Step 1 — Build

```bash
swift build 2>&1
```

Expected: `Build complete!` with zero errors or warnings related to Lattice.

### Step 2 — Emission normalization tests

```bash
swift test --filter EmissionAppendTests 2>&1
```

Expected: All tests pass. Validates flattening, `.none` dropping, single-child collapse, `.then`/`.appending` equivalence, and `.map` propagation.

### Step 3 — Debounce propagation

```bash
swift test --filter EmissionDebounceTests 2>&1
```

Expected: All existing tests pass + new `appendDebouncesPerformChildren` passes.

### Step 4 — ViewModel sequential execution

```bash
swift test --filter ViewModelAppendTests 2>&1
```

Expected: All tests pass. Validates ordering, `.finish()` completion, cancellation, nil-perform passthrough, and merge-within-append behavior.

### Step 5 — InteractorTestHarness parity

```bash
swift test --filter InteractorTestHarnessAppendTests 2>&1
```

Expected: All tests pass. Validates that harness mirrors ViewModel ordering, records correct action/state history, and respects cancellation.

### Step 6 — Observe sequencing

```bash
swift test --filter EmissionAppendObserveTests 2>&1
```

Expected: `finiteObserveCompletesBeforeNextStep` passes.

### Step 7 — Full regression suite

```bash
swift test 2>&1
```

Expected: All tests pass. No regressions in existing merge, debounce, ViewModel, or harness behavior.

### Step 8 — Format

```bash
swift-format format --in-place --recursive Sources Tests
```

---

## File Change Summary

| File | Action |
|---|---|
| `Sources/Lattice/Domain/Emission.swift` | Add `.append` case, static APIs, `.then`, update `.map` |
| `Sources/Lattice/Domain/Emission+Debounce.swift` | Add `.append` case to `debounce` |
| `Sources/Lattice/Presentation/ViewModel/ViewModel.swift` | Add `.append` case to `spawnTasks` |
| `Sources/Lattice/Testing/InteractorTestHarness.swift` | Add `.append` case to `spawnTasks` |
| `Tests/LatticeTests/DomainTests/EmissionAppendTests.swift` | **New file** |
| `Tests/LatticeTests/DomainTests/EmissionAppendObserveTests.swift` | **New file** |
| `Tests/LatticeTests/DomainTests/EmissionDebounceTests.swift` | Add `appendDebouncesPerformChildren` test |
| `Tests/LatticeTests/PresentationTests/ViewModelAppendTests.swift` | **New file** |
| `Tests/LatticeTests/TestingInfrastructureTests/InteractorTestHarnessAppendTests.swift` | **New file** |

## Behavior Contract

1. `.merge` remains concurrent.
2. `.append` is strictly ordered: step N+1 starts only after step N has terminated.
3. Termination includes normal completion and child-level cancellation/no-op completion (`.none`, `.perform` returning `nil`, finished/cancelled stream).
4. Canceling the outer `EventTask`/harness task cancels the currently running appended step and prevents later steps from starting.
5. `.observe` in an appended step blocks subsequent steps until it terminates.
