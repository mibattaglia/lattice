# Phase 4: Migrate All Interactors - Implementation Plan

## Overview

Phase 4 focuses on migrating all example interactors and their tests from Combine to AsyncStream. This phase assumes Phases 1-3 are complete.

## Files to Migrate

**Example Interactors:**
1. `Tests/.../CounterInteractors/CounterInteractor.swift`
2. `Tests/.../CounterInteractors/AsyncCounterInteractor.swift`
3. `Tests/.../CounterInteractors/HotCounterInteractor.swift`
4. `Examples/Search/Search/Architecture/SearchInteractor.swift`
5. `Examples/Search/Search/Architecture/SearchQueryInteractor.swift`

**Test Stubs:**
6. `Tests/.../InteractorsTests/Stubs.swift`

**Test Files:**
7. `Tests/.../CounterInteractors/CounterInteractorTests.swift`
8. `Tests/.../CounterInteractors/AsyncCounterInteractorTests.swift`
9. `Tests/.../CounterInteractors/HotCounterInteractorTests.swift`
10. `Tests/.../InteractorsTests/Interactors+DebounceTests.swift`
11. `Tests/.../InteractorsTests/Interactors+MergeTests.swift`
12. `Tests/.../InteractorsTests/Interactors+MergeManyTests.swift`
13. `Tests/.../InteractorsTests/Interactors+WhenTests.swift`
14. `Tests/.../InteractorBuilderTests.swift`

## What We're NOT Doing

- Core infrastructure (Phase 1)
- Higher-order interactors (Phase 2)
- Testing infrastructure (Phase 3)
- ViewModel integration (Phase 5)
- Cleanup (Phase 6)

---

## Key Migration Patterns

### Pattern 1: Simple State Mutation (CounterInteractor)

**No changes needed** - The `Interact` primitive handles the AsyncStream conversion.

---

### Pattern 2: Async Work with Clock (AsyncCounterInteractor)

**Before (CombineSchedulers):**
```swift
import CombineSchedulers

private let scheduler: AnySchedulerOf<DispatchQueue>

return .perform { [count = state.count] in
    try? await scheduler.sleep(for: .seconds(0.5))
    return AsyncCounterInteractor.DomainState(count: count + 1)
}
```

**After (Clock protocol with Send callback):**
```swift
private let clock: any Clock<Duration>

return .perform { [clock] send in
    try? await clock.sleep(for: .milliseconds(500))
    await send(State(count: count + 1))
}
```

---

### Pattern 3: Observing External Streams (HotCounterInteractor)

**Before (Combine):**
```swift
case let .observe(publisher):
    return .observe { state in
        publisher.map { int in
            DomainState(count: state.count + int)
        }.eraseToAnyPublisher()
    }
```

**After (AsyncStream with Send callback):**
```swift
case let .observe(stream):
    return .observe { currentState, send in
        for await int in stream {
            let count = await currentState.count
            await send(DomainState(count: count + int))
        }
    }
```

---

### Pattern 4: Test Migration

**Before (Combine):**
```swift
private let subject = PassthroughSubject<Action, Never>()
private var cancellables: Set<AnyCancellable> = []

counterInteractor
    .interact(subject.eraseToAnyPublisher())
    .collect()
    .sink { actual in #expect(actual == expected) }
    .store(in: &cancellables)

subject.send(.increment)
subject.send(completion: .finished)
```

**After (InteractorTestHarness):**
```swift
let harness = await InteractorTestHarness(counterInteractor)

await harness.send(.increment)
await harness.finish()

try await harness.assertStates(expected)
```

---

## Implementation Steps

### Step 1: Migrate CounterInteractor

**No changes needed** - Already uses `Interact` with `.state` emission.

---

### Step 2: Migrate AsyncCounterInteractor

**File**: `Tests/.../CounterInteractors/AsyncCounterInteractor.swift`

```swift
import Foundation
@testable import UnoArchitecture

@Interactor
struct AsyncCounterInteractor {
    struct State: Equatable, Sendable { var count: Int }
    enum Action: Sendable { case increment, async }

    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    var body: some Interactor<State, Action> {
        Interact<State, Action>(initialValue: State(count: 0)) { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .state
            case .async:
                let count = state.count
                return .perform { [clock] send in
                    try? await clock.sleep(for: .milliseconds(500))
                    await send(State(count: count + 1))
                }
            }
        }
    }
}
```

---

### Step 3: Migrate HotCounterInteractor

**File**: `Tests/.../CounterInteractors/HotCounterInteractor.swift`

```swift
import Foundation
@testable import UnoArchitecture

struct HotCounterInteractor: Interactor {
    struct DomainState: Equatable, Sendable { var count: Int }
    enum Action: Sendable {
        case increment
        case observe(AsyncStream<Int>)
    }

    var body: some InteractorOf<Self> {
        Interact<DomainState, Action>(initialValue: DomainState(count: 0)) { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .state
            case let .observe(stream):
                return .observe { currentState, send in
                    for await int in stream {
                        let count = await currentState.count
                        await send(DomainState(count: count + int))
                    }
                }
            }
        }
    }
}
```

---

### Step 4: Migrate Test Stubs

**File**: `Tests/.../InteractorsTests/Stubs.swift`

```swift
import UnoArchitecture

struct DoubleInteractor: Interactor {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(_ upstream: AsyncStream<Int>) -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task {
                for await value in upstream {
                    continuation.yield(value * 2)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct TripleInteractor: Interactor {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(_ upstream: AsyncStream<Int>) -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task {
                for await value in upstream {
                    continuation.yield(value * 3)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

---

### Step 5: Migrate CounterInteractorTests

**File**: `Tests/.../CounterInteractors/CounterInteractorTests.swift`

```swift
import Foundation
import Testing
@testable import UnoArchitecture

@Suite
final class CounterInteractorTests {
    private let counterInteractor = CounterInteractor()

    @Test func increment() async throws {
        let expected: [CounterInteractor.DomainState] = [
            .init(count: 0), .init(count: 1), .init(count: 2), .init(count: 3),
        ]

        let harness = await InteractorTestHarness(counterInteractor)

        for _ in 1..<4 { await harness.send(.increment) }
        await harness.finish()

        try await harness.assertStates(expected)
    }
}
```

---

### Step 6: Migrate AsyncCounterInteractorTests

**File**: `Tests/.../CounterInteractors/AsyncCounterInteractorTests.swift`

```swift
import Foundation
import Testing
@testable import UnoArchitecture

@Suite
final class AsyncCounterInteractorTests {
    @Test func asyncWork() async throws {
        let clock = TestClock()
        let counterInteractor = AsyncCounterInteractor(clock: clock)

        let expected: [AsyncCounterInteractor.DomainState] = [
            .init(count: 0), .init(count: 1), .init(count: 2), .init(count: 3),
        ]

        let harness = await InteractorTestHarness(counterInteractor)

        await harness.send(.increment)
        await harness.send(.async)
        await clock.advance(by: .milliseconds(500))
        await harness.send(.increment)
        await harness.finish()

        try await harness.assertStates(expected)
    }
}
```

---

### Step 7: Migrate HotCounterInteractorTests

**File**: `Tests/.../CounterInteractors/HotCounterInteractorTests.swift`

```swift
import Foundation
import Testing
@testable import UnoArchitecture

@Suite
final class HotCounterInteractorTests {
    @Test func asyncWork() async throws {
        let expected: [HotCounterInteractor.DomainState] = [
            .init(count: 0), .init(count: 1), .init(count: 2), .init(count: 4), .init(count: 5),
        ]

        let counterInteractor = HotCounterInteractor()
        let harness = await InteractorTestHarness(counterInteractor)

        await harness.send(.increment)

        let (intStream, intContinuation) = AsyncStream<Int>.makeStream()
        await harness.send(.observe(intStream))
        intContinuation.yield(1)
        intContinuation.yield(2)

        await harness.send(.increment)
        intContinuation.finish()
        await harness.finish()

        try await harness.assertStates(expected)
    }
}
```

---

### Step 8: Migrate Search Example Interactors

**Files**:
- `Examples/Search/Search/Architecture/SearchInteractor.swift`
- `Examples/Search/Search/Architecture/SearchQueryInteractor.swift`

Key changes:
1. Remove `import Combine` and `import CombineSchedulers`
2. Replace `AnySchedulerOf<DispatchQueue>` with `any Clock<Duration>`
3. Update `.perform` to use `Send` callback pattern
4. Update `DebounceInteractor` to use `clock` parameter

---

## Success Criteria

### Automated Verification

```bash
swift build
swift test
```

### Verification Commands

```bash
# No Combine imports in example interactors
grep -r "import Combine" Tests/.../CounterInteractors/
grep -r "import Combine" Examples/Search/Search/Architecture/

# No CombineSchedulers imports
grep -r "import CombineSchedulers" Tests/.../CounterInteractors/
grep -r "import CombineSchedulers" Examples/Search/Search/Architecture/
```

---

## Dependencies

- Phase 1: Core infrastructure
- Phase 2: Higher-order interactors
- Phase 3: Testing infrastructure (`TestClock`, `InteractorTestHarness`)

---

## Critical Files for Implementation

| File | Purpose |
|------|---------|
| `Tests/.../AsyncCounterInteractor.swift` | Example of `.perform` pattern with clock |
| `Tests/.../HotCounterInteractor.swift` | Example of `.observe` pattern |
| `Examples/Search/.../SearchInteractor.swift` | Complex real-world example |
| `Tests/.../Interactors+DebounceTests.swift` | Testing with TestClock |
| `Tests/.../Stubs.swift` | Custom Interactor implementations |
