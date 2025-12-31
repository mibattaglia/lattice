# Phase 3: Testing Infrastructure - Implementation Plan

## Overview

Phase 3 creates first-class testing utilities for AsyncStream-based interactors, enabling deterministic time control and ergonomic emission recording. The testing infrastructure replaces Combine's `TestScheduler` pattern with Swift's native `Clock` protocol.

## Current State Analysis

**Current Test Patterns:**
- Tests use Swift Testing framework (`@Suite`, `@Test`, `#expect`)
- Combine-based testing with `PassthroughSubject` for action injection
- `TestScheduler` from combine-schedulers for deterministic time control
- `.collect()` and `.sink` for emission capture

**Target AsyncStream Testing:**
- `TestClock` for deterministic time control
- `AsyncStreamRecorder` for emission capture
- `InteractorTestHarness` for ergonomic testing
- `for await` instead of `.sink`

## Desired End State

**New Files:**
```
Sources/UnoArchitecture/
  Testing/
    TestClock.swift
    TestInstant.swift
    AsyncStreamRecorder.swift
    InteractorTestHarness.swift
```

## What We're NOT Doing

- Migrating existing Combine-based tests (Phase 4)
- UI testing utilities
- Performance benchmarking infrastructure

---

## Implementation Steps

### Step 1: Create TestInstant

**File**: `Sources/UnoArchitecture/Testing/TestInstant.swift` (NEW)

```swift
import Foundation

/// A point in time for TestClock, representing an offset from the clock's start.
public struct TestInstant: InstantProtocol, Hashable, Sendable {
    public let offset: Duration

    public init(offset: Duration) {
        self.offset = offset
    }

    public func advanced(by duration: Duration) -> TestInstant {
        TestInstant(offset: offset + duration)
    }

    public func duration(to other: TestInstant) -> Duration {
        other.offset - offset
    }

    public static func < (lhs: TestInstant, rhs: TestInstant) -> Bool {
        lhs.offset < rhs.offset
    }
}
```

---

### Step 2: Create TestClock

**File**: `Sources/UnoArchitecture/Testing/TestClock.swift` (NEW)

```swift
import Foundation

/// A controllable clock for deterministic testing of time-based operations.
///
/// Usage:
/// ```swift
/// @Test func testDebounce() async throws {
///     let clock = TestClock()
///     let debounced = actions.debounce(for: .seconds(1), clock: clock)
///
///     actionContinuation.yield(.search("query"))
///     await clock.advance(by: .seconds(1))
///     try await recorder.waitForEmissions(count: 1)
/// }
/// ```
public actor TestClock: Clock, Sendable {
    public typealias Duration = Swift.Duration
    public typealias Instant = TestInstant

    private var _now: TestInstant
    private var sleepers: [(id: UUID, deadline: TestInstant, continuation: CheckedContinuation<Void, Never>)] = []

    public init(now: TestInstant = TestInstant(offset: .zero)) {
        self._now = now
    }

    public var now: TestInstant { _now }

    public nonisolated var minimumResolution: Duration { .nanoseconds(1) }

    public func sleep(until deadline: TestInstant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        guard deadline > _now else { return }

        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sleepers.append((id: id, deadline: deadline, continuation: continuation))
            sleepers.sort { $0.deadline < $1.deadline }
        }
    }

    /// Advances the clock by the given duration, waking sleepers.
    public func advance(by duration: Duration) async {
        let targetTime = _now.advanced(by: duration)
        await advanceTo(targetTime)
    }

    public func advanceTo(_ instant: TestInstant) async {
        guard instant > _now else { return }

        while let first = sleepers.first, first.deadline <= instant {
            _now = first.deadline
            sleepers.removeFirst()
            first.continuation.resume()
            await Task.yield()
        }
        _now = instant
    }

    /// Runs until all pending sleepers have been woken.
    public func runToCompletion() async {
        while let last = sleepers.last {
            await advanceTo(last.deadline)
        }
    }

    public var pendingSleepersCount: Int { sleepers.count }
}
```

---

### Step 3: Create AsyncStreamRecorder

**File**: `Sources/UnoArchitecture/Testing/AsyncStreamRecorder.swift` (NEW)

```swift
import Foundation

/// Records all emissions from an AsyncSequence for test assertions.
public actor AsyncStreamRecorder<Element: Sendable> {
    public private(set) var values: [Element] = []
    private var task: Task<Void, Never>?
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isFinished = false

    public init() {}

    public func record<S: AsyncSequence & Sendable>(_ sequence: S) where S.Element == Element {
        task = Task { [weak self] in
            do {
                for try await element in sequence {
                    guard let self = self else { return }
                    await self.append(element)
                }
                await self?.markFinished()
            } catch {
                await self?.markFinished()
            }
        }
    }

    private func append(_ element: Element) {
        values.append(element)
        checkWaiters()
    }

    private func markFinished() {
        isFinished = true
        checkWaiters()
    }

    /// Waits until at least `count` emissions have been recorded.
    public func waitForEmissions(count: Int, timeout: Duration = .seconds(5)) async throws {
        if values.count >= count || isFinished { return }

        let currentCount = values.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { [weak self] continuation in
                    Task { await self?.addWaiter(count: count, continuation: continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError(expectedCount: count, actualCount: currentCount)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func addWaiter(count: Int, continuation: CheckedContinuation<Void, Never>) {
        if values.count >= count || isFinished {
            continuation.resume()
        } else {
            waiters.append((count: count, continuation: continuation))
        }
    }

    public func waitForNextEmission(timeout: Duration = .seconds(5)) async throws {
        try await waitForEmissions(count: values.count + 1, timeout: timeout)
    }

    public func cancel() {
        task?.cancel()
        task = nil
        for waiter in waiters { waiter.continuation.resume() }
        waiters.removeAll()
    }

    private func checkWaiters() {
        waiters.removeAll { waiter in
            if values.count >= waiter.count || isFinished {
                waiter.continuation.resume()
                return true
            }
            return false
        }
    }

    public var lastValue: Element? { values.last }

    public struct TimeoutError: Error, CustomStringConvertible {
        public let expectedCount: Int
        public let actualCount: Int
        public var description: String {
            "Timed out waiting for \(expectedCount) emissions, only received \(actualCount)"
        }
    }
}
```

---

### Step 4: Create InteractorTestHarness

**File**: `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift` (NEW)

```swift
import Foundation

/// A test harness that simplifies interactor testing.
///
/// Usage:
/// ```swift
/// @Test func testCounter() async throws {
///     let harness = await InteractorTestHarness(CounterInteractor())
///
///     await harness.send(.increment)
///     await harness.send(.increment)
///
///     try await harness.assertStates([
///         .init(count: 0),
///         .init(count: 1),
///         .init(count: 2)
///     ])
/// }
/// ```
@MainActor
public final class InteractorTestHarness<State: Sendable, Action: Sendable> {
    private let actionContinuation: AsyncStream<Action>.Continuation
    private let recorder: AsyncStreamRecorder<State>

    public init<I: Interactor>(_ interactor: I) async
    where I.DomainState == State, I.Action == Action {
        let (actionStream, continuation) = AsyncStream<Action>.makeStream()
        self.actionContinuation = continuation
        self.recorder = AsyncStreamRecorder<State>()

        let stateStream = interactor.interact(actionStream)
        await recorder.record(stateStream)
    }

    public func send(_ action: Action) {
        actionContinuation.yield(action)
    }

    public func send(_ actions: Action...) {
        for action in actions { actionContinuation.yield(action) }
    }

    public func finish() {
        actionContinuation.finish()
    }

    public var states: [State] {
        get async { await recorder.values }
    }

    public var latestState: State? {
        get async { await recorder.lastValue }
    }

    public func waitForStates(count: Int, timeout: Duration = .seconds(5)) async throws {
        try await recorder.waitForEmissions(count: count, timeout: timeout)
    }

    public func assertStates(
        _ expected: [State],
        timeout: Duration = .seconds(5),
        file: StaticString = #file,
        line: UInt = #line
    ) async throws where State: Equatable {
        try await waitForStates(count: expected.count, timeout: timeout)
        let actual = await states

        guard actual.prefix(expected.count) == expected[...] else {
            throw AssertionError(
                message: "States mismatch.\nExpected: \(expected)\nActual: \(Array(actual.prefix(expected.count)))",
                file: file,
                line: line
            )
        }
    }

    public func assertLatestState(
        _ expected: State,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws where State: Equatable {
        let latest = await latestState
        guard latest == expected else {
            throw AssertionError(
                message: "Latest state mismatch.\nExpected: \(expected)\nActual: \(String(describing: latest))",
                file: file,
                line: line
            )
        }
    }

    public struct AssertionError: Error, CustomStringConvertible {
        public let message: String
        public let file: StaticString
        public let line: UInt
        public var description: String { message }
    }

    deinit {
        actionContinuation.finish()
        Task { [recorder] in await recorder.cancel() }
    }
}
```

---

## Test Examples

### TestClock Tests

**File**: `Tests/UnoArchitectureTests/TestingInfrastructureTests/TestClockTests.swift`

```swift
import Testing
@testable import UnoArchitecture

@Suite
struct TestClockTests {
    @Test
    func advanceByDuration() async {
        let clock = TestClock()
        var woken = false

        Task {
            try? await clock.sleep(until: TestInstant(offset: .seconds(1)), tolerance: nil)
            woken = true
        }

        // Wait for the sleeper to register
        while await clock.pendingSleepersCount == 0 {
            await Task.yield()
        }
        #expect(!woken)

        await clock.advance(by: .seconds(1))
        await Task.yield()
        #expect(woken)
    }

    @Test
    func sleepersWakeInDeadlineOrder() async {
        let clock = TestClock()
        var wakeOrder: [Int] = []

        Task { try? await clock.sleep(until: TestInstant(offset: .seconds(2)), tolerance: nil); wakeOrder.append(2) }
        Task { try? await clock.sleep(until: TestInstant(offset: .seconds(1)), tolerance: nil); wakeOrder.append(1) }
        Task { try? await clock.sleep(until: TestInstant(offset: .seconds(3)), tolerance: nil); wakeOrder.append(3) }

        while await clock.pendingSleepersCount < 3 {
            await Task.yield()
        }

        await clock.runToCompletion()
        #expect(wakeOrder == [1, 2, 3])
    }
}
```

### AsyncStreamRecorder Tests

**File**: `Tests/UnoArchitectureTests/TestingInfrastructureTests/AsyncStreamRecorderTests.swift`

```swift
import Testing
@testable import UnoArchitecture

@Suite
struct AsyncStreamRecorderTests {
    @Test
    func recordsEmissions() async throws {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let recorder = AsyncStreamRecorder<Int>()

        await recorder.record(stream)

        continuation.yield(1)
        continuation.yield(2)
        continuation.yield(3)

        try await recorder.waitForEmissions(count: 3)
        #expect(await recorder.values == [1, 2, 3])

        continuation.finish()
    }
}
```

### InteractorTestHarness Tests

**File**: `Tests/UnoArchitectureTests/TestingInfrastructureTests/InteractorTestHarnessTests.swift`

```swift
import Testing
@testable import UnoArchitecture

// Simple counter interactor for testing
struct CounterState: Equatable, Sendable {
    var count: Int = 0
}

enum CounterAction: Sendable {
    case increment
    case decrement
}

struct CounterInteractor: Interactor {
    var body: some Interactor<CounterState, CounterAction> {
        Interact(initialValue: CounterState()) { state, action in
            switch action {
            case .increment: state.count += 1
            case .decrement: state.count -= 1
            }
            return .state
        }
    }
}

@Suite
struct InteractorTestHarnessTests {
    @Test
    func sendActionsAndAssertStates() async throws {
        let harness = await InteractorTestHarness(CounterInteractor())

        harness.send(.increment)
        harness.send(.increment)
        harness.send(.decrement)

        try await harness.assertStates([
            CounterState(count: 0),  // initial
            CounterState(count: 1),
            CounterState(count: 2),
            CounterState(count: 1)
        ])
    }

    @Test
    func assertLatestState() async throws {
        let harness = await InteractorTestHarness(CounterInteractor())

        harness.send(.increment)
        harness.send(.increment)

        try await harness.waitForStates(count: 3)
        try await harness.assertLatestState(CounterState(count: 2))
    }
}
```

---

## Success Criteria

### Automated Verification

```bash
swift build
swift test --filter TestClockTests
swift test --filter AsyncStreamRecorderTests
swift test --filter InteractorTestHarnessTests
```

### Manual Verification

1. **TestClock Determinism**: Sleepers wake in deadline order
2. **AsyncStreamRecorder Reliability**: Emissions recorded in order, timeout works
3. **InteractorTestHarness Ergonomics**: send/assert pattern is intuitive

---

## Dependencies

- Phase 1 (Core Infrastructure) for `Interactor` protocol
- Phase 2 (Higher-Order Interactors) for `Debounce` testing examples

## Alignment Notes

**Protocol Constraints (from Phase 1/2):**
- `Interactor` protocol requires `DomainState: Sendable` and `Action: Sendable`
- `InteractorTestHarness` mirrors these constraints: `<State: Sendable, Action: Sendable>`
- `AsyncStreamRecorder` requires `Element: Sendable` for actor isolation compatibility

**Actor Isolation Strategy:**
- `Interactor` protocol is NOT `@MainActor` bound - implementers choose their own isolation
- Testing infrastructure (`InteractorTestHarness`) IS `@MainActor` for testing ergonomics
- This allows synchronous `send()` calls and easy state assertions from test methods

**Concurrency Safety:**
- `AsyncStreamRecorder.record()` requires `S: AsyncSequence & Sendable` to safely capture the sequence in a Task
- `TimeoutError` includes actual count for better diagnostics

---

## Critical Files for Implementation

| File | Purpose |
|------|---------|
| `Sources/UnoArchitecture/Testing/TestClock.swift` | Core time control |
| `Sources/UnoArchitecture/Testing/AsyncStreamRecorder.swift` | Emission capture |
| `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift` | Ergonomic wrapper |
