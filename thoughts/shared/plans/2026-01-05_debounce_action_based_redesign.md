# Debounce for Action-Based Emissions - Implementation Plan

## Overview

Redesign the `Debouncer` and `Debounce` interactor to work with the new action-based `Emission<Action>` model. The current `Debouncer` returns `Task<Void, Never>`, but for action-based emissions, we need it to return values that can be used as actions. We'll explore two approaches: (A) Debounce as an Emission extension and (B) Debounce as a higher-order interactor.

## Current State Analysis

### Existing Debouncer (`Sources/UnoArchitecture/Internal/Debouncer.swift`)

The current `Debouncer` actor:
- Delays and coalesces work, executing only after a quiet period
- Returns `Task<Void, Never>` from `debounce(_:)`
- Cancels previous work when new work arrives
- Uses `TestClock` injection for testing

```swift
public actor Debouncer<C: Clock> where C.Duration: Sendable {
    @discardableResult
    public func debounce(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never>
}
```

### Problem: No Return Value

Effects in `Emission<Action>` need to return actions:
```swift
case .perform(work: @Sendable () async -> Action?)
```

The current `Debouncer` executes work but can't return the action value back to the caller.

### Key Discoveries

1. **TCA Pattern**: Uses `cancellable(id:, cancelInFlight: true)` combined with delay - each new effect cancels previous ([TCA Debounce.swift](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Effects/Debounce.swift))
2. **Swift AsyncAlgorithms**: Provides `debounce(for:clock:)` on AsyncSequence ([Apple docs](https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Debounce.md))
3. **Resource Efficiency**: Single debouncer actor with task cancellation is efficient - no task explosion

## Desired End State

After implementation:

1. **DebounceResult type**: Explicit enum distinguishing `.executed(T)` from `.superseded`
2. **Debouncer returns Task**: `debounce(_ work:) -> Task<DebounceResult<T>, Never>` - no suspension inside actor
3. **Emission.debounce extension**: Fine-grained debouncing of individual effects
4. **Debounce interactor (optional)**: Higher-order interactor for wrapping entire features
5. **Full test coverage**: Both Debouncer and Debounce interactor independently testable
6. **Resource efficient**: Rapid calls don't create task explosion

### Verification

```swift
// Debouncer standalone test - debounce() returns Task, caller awaits .value
let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)
let t1 = await debouncer.debounce { 1 }  // Returns Task immediately
let t2 = await debouncer.debounce { 2 }  // Cancels t1, returns new Task
let t3 = await debouncer.debounce { 3 }  // Cancels t2, returns new Task

await clock.advance(by: .milliseconds(300))

#expect(await t1.value == .superseded)
#expect(await t2.value == .superseded)
#expect(await t3.value == .executed(3))

// Emission extension test - clear distinction between:
// - .executed(nil): work ran, chose not to emit action
// - .superseded: work was cancelled, never ran
let emission = Emission<Action>.perform { .searchCompleted(results) }
    .debounce(using: debouncer)
```

## What We're NOT Doing

- **Not adding AsyncAlgorithms dependency**: We'll implement debounce internally
- **Not changing Emission's core types**: Only adding extension methods
- **Not maintaining backwards compatibility**: All existing Debouncer usages will be updated to the new generic API
- **Not implementing throttle**: Only debounce for this plan

## Implementation Approach

We'll implement **both approaches** as they serve different use cases:

| Approach | Use Case | Example |
|----------|----------|---------|
| Emission extension | Debounce specific effects | Search API calls |
| Debounce interactor | Debounce all actions to a feature | Entire search feature |

The key enabler is a new `Debouncer` API that returns values.

---

## Phase 1: Add DebounceResult and Update Debouncer

### Overview

Add a `DebounceResult<T>` enum that explicitly distinguishes between executed work and superseded work. Update `Debouncer` to return this type instead of `T?`.

### Why DebounceResult?

Returning `T?` conflates two semantically different outcomes:
- `nil` because work was superseded (never ran)
- `nil` because work ran and intentionally returned no value

With `DebounceResult<T>`, we have clear semantics:
- `.executed(T)` - work ran and returned a value
- `.superseded` - work was cancelled by a newer call

This is especially important when `T` is itself optional (like `Action?`), where `.executed(nil)` means "work ran, chose not to emit" while `.superseded` means "work never ran".

### Changes Required

#### 1. Add DebounceResult Type

**File**: `Sources/UnoArchitecture/Internal/DebounceResult.swift` (new file)

```swift
/// The result of a debounced operation.
///
/// `DebounceResult` distinguishes between work that executed and work that was
/// superseded by a newer call. This is important when the work's return type
/// is itself optional, as it preserves the semantic difference between
/// "work ran and returned nil" vs "work was cancelled".
///
/// ## Example
///
/// ```swift
/// let result = await debouncer.debounce { fetchData() }
/// switch result {
/// case .executed(let data):
///     // Work completed, use data
/// case .superseded:
///     // Work was cancelled by a newer call
/// }
/// ```
public enum DebounceResult<T: Sendable>: Sendable {
    /// The work executed and returned a value.
    case executed(T)

    /// The work was superseded by a newer debounce call and did not execute.
    case superseded
}

extension DebounceResult: Equatable where T: Equatable {}
```

#### 2. Update Debouncer

**File**: `Sources/UnoArchitecture/Internal/Debouncer.swift`

**Key Design Decision**: The `debounce` method returns a `Task` instead of being `async`. This eliminates suspension points inside the actor, avoiding actor re-entrancy concerns. All state mutations (generation increment, task cancellation, task storage) happen synchronously before returning.

```swift
/// A utility that delays and coalesces work, executing only after a quiet period.
///
/// When `debounce` is called multiple times rapidly, only the last work closure
/// executes after the debounce duration elapses with no new calls.
///
/// ## Usage
///
/// ```swift
/// let debouncer = Debouncer<ContinuousClock, Int>(for: .milliseconds(300), clock: ContinuousClock())
///
/// // Rapid calls - only the last one executes
/// let t1 = await debouncer.debounce { 1 }  // Returns Task, will be .superseded
/// let t2 = await debouncer.debounce { 2 }  // Cancels t1, will be .superseded
/// let t3 = await debouncer.debounce { 3 }  // Cancels t2, will be .executed(3)
///
/// // Await results
/// await t1.value  // .superseded
/// await t3.value  // .executed(3) after 300ms
/// ```
public actor Debouncer<C: Clock, T: Sendable> where C.Duration: Sendable {
    private let duration: C.Duration
    private let clock: C
    private var currentGeneration: UInt64 = 0
    private var currentTask: Task<DebounceResult<T>, Never>?

    /// Creates a debouncer with the specified duration and clock.
    ///
    /// - Parameters:
    ///   - duration: How long to wait after the last call before executing.
    ///   - clock: The clock to use for timing. Inject `TestClock` for testing.
    public init(for duration: C.Duration, clock: C) {
        self.duration = duration
        self.clock = clock
    }

    /// Schedules work to execute after the debounce period.
    ///
    /// If called again before the period elapses, the previous work is cancelled
    /// and the timer resets. Only the last work closure will execute.
    ///
    /// This method does not suspend - it returns a Task immediately. The caller
    /// awaits the Task's value to get the result. This design avoids actor
    /// re-entrancy issues by keeping all state mutations synchronous.
    ///
    /// - Parameter work: The closure to execute after debouncing.
    /// - Returns: A Task that resolves to `.executed(T)` or `.superseded`.
    public func debounce(_ work: @escaping @Sendable () async -> T) -> Task<DebounceResult<T>, Never> {
        currentGeneration &+= 1
        let myGeneration = currentGeneration
        currentTask?.cancel()

        let task = Task<DebounceResult<T>, Never> { [weak self, duration, clock] in
            do {
                try await clock.sleep(for: duration)

                // Check if we're still the current generation
                guard let self else { return .superseded }
                guard await self.isCurrentGeneration(myGeneration) else { return .superseded }
                guard !Task.isCancelled else { return .superseded }

                return .executed(await work())
            } catch {
                // Sleep threw CancellationError
                return .superseded
            }
        }

        currentTask = task
        return task
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        generation == currentGeneration
    }
}
```

#### 3. Add Convenience Initializer for ContinuousClock

**File**: `Sources/UnoArchitecture/Internal/Debouncer.swift` (append)

```swift
extension Debouncer where C == ContinuousClock {
    /// Creates a debouncer with the specified duration using the continuous clock.
    ///
    /// - Parameter duration: How long to wait after the last call before executing.
    public init(for duration: Duration) {
        self.init(for: duration, clock: ContinuousClock())
    }
}
```


### Success Criteria

#### Automated Verification:
- [x] `swift build` compiles successfully
- [x] `swift test --filter DebouncerTests` passes all existing tests
- [x] New generic tests pass

#### Manual Verification:
- [ ] Verify debounce returns correct value in playground/sample

---

## Phase 2: Update Debouncer Tests

### Overview

Update tests to verify `DebounceResult` behavior - distinguishing between `.executed(T)` and `.superseded`.

### Changes Required

#### 1. Update DebouncerTests

**File**: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/DebouncerTests.swift`

**Note**: Tests use `Task.detached` for concurrent calls to ensure proper actor message ordering.

```swift
import Clocks
import Foundation
import Testing

@testable import UnoArchitecture

@Suite
struct DebouncerTests {

    // MARK: - Basic Execution Tests

    @Test
    func debounceReturnsExecutedAfterDuration() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)

        let task = await debouncer.debounce { 42 }

        await clock.advance(by: .milliseconds(300))

        #expect(await task.value == .executed(42))
    }

    @Test
    func debounceDelaysExecution() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)

        let task = await debouncer.debounce {
            await counter.increment()
            return await counter.value
        }

        // Work should NOT have executed yet
        #expect(await counter.value == 0)

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))

        // Now work should have executed
        #expect(await task.value == .executed(1))
        #expect(await counter.value == 1)
    }

    // MARK: - Superseded Tests

    @Test
    func onlyLastCallerGetsExecutedResult() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, String>(for: .milliseconds(300), clock: clock)

        // Use Task.detached to create concurrent calls to the actor
        let task1 = Task.detached { await debouncer.debounce { "first" } }
        let task2 = Task.detached { await debouncer.debounce { "second" } }
        let task3 = Task.detached { await debouncer.debounce { "third" } }

        // Give tasks time to enqueue on the actor
        await Task.yield()
        await Task.yield()
        await Task.yield()

        await clock.advance(by: .milliseconds(300))

        let results = await [task1.value.value, task2.value.value, task3.value.value]

        // Exactly one should be executed, the rest superseded
        let executedCount = results.filter { if case .executed = $0 { return true } else { return false } }.count
        let supersededCount = results.filter { if case .superseded = $0 { return true } else { return false } }.count

        #expect(executedCount == 1, "Exactly one call should execute")
        #expect(supersededCount == 2, "Two calls should be superseded")
    }

    @Test
    func onlyLastWorkClosureExecutes() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)
        let counter = Counter()

        // Use Task.detached to create concurrent calls
        let task1 = Task.detached {
            await debouncer.debounce {
                await counter.increment()
                return 1
            }
        }
        let task2 = Task.detached {
            await debouncer.debounce {
                await counter.increment()
                return 2
            }
        }
        let task3 = Task.detached {
            await debouncer.debounce {
                await counter.increment()
                return 3
            }
        }

        // Give tasks time to enqueue
        await Task.yield()
        await Task.yield()
        await Task.yield()

        await clock.advance(by: .milliseconds(300))

        let results = await [task1.value.value, task2.value.value, task3.value.value]

        // Only the third closure executed
        #expect(await counter.value == 1)
        #expect(results == [.superseded, .superseded, .executed(3)])
    }

    // MARK: - Optional Value Tests (Key semantic distinction)

    @Test
    func executedNilIsDistinctFromSuperseded() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, Int?>(for: .milliseconds(300), clock: clock)

        // Work that intentionally returns nil
        let task = await debouncer.debounce { nil as Int? }

        await clock.advance(by: .milliseconds(300))

        // .executed(nil) is NOT the same as .superseded
        let value = await task.value
        #expect(value == .executed(nil))

        // Verify it's truly .executed, not .superseded
        if case .executed(let inner) = value {
            #expect(inner == nil)
        } else {
            Issue.record("Expected .executed(nil), got .superseded")
        }
    }

    // MARK: - Timer Reset Tests

    @Test
    func callMidDebounceResetsTimer() async throws {
        let clock = TestClock()
        let result = ResultHolder()

        let debouncer = Debouncer<TestClock, String>(for: .milliseconds(300), clock: clock)

        // First call - start debounce
        let task1 = Task.detached {
            await debouncer.debounce {
                await result.set("first")
                return "first"
            }
        }

        // Give time to start
        await Task.yield()

        // Advance partially (not enough to trigger)
        await clock.advance(by: .milliseconds(200))
        #expect(await result.value == "")

        // Second call resets the timer
        let task2 = Task.detached {
            await debouncer.debounce {
                await result.set("second")
                return "second"
            }
        }

        await Task.yield()

        // Advance another 200ms (total 400ms, but only 200ms since second call)
        await clock.advance(by: .milliseconds(200))
        #expect(await result.value == "")

        // Advance remaining 100ms to complete second debounce
        await clock.advance(by: .milliseconds(100))

        // Only second work executed
        #expect(await result.value == "second")
        #expect(await task1.value.value == .superseded)
        #expect(await task2.value.value == .executed("second"))
    }

    // MARK: - Cancellation Tests

    @Test
    func newCallCancelsPreviousWork() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)

        // First call starts debouncing
        let task1 = Task.detached {
            await debouncer.debounce {
                await counter.increment()
                return 1
            }
        }

        await Task.yield()

        // Second call should cancel the first
        let task2 = Task.detached {
            await debouncer.debounce {
                await counter.increment()
                return 2
            }
        }

        await Task.yield()

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))

        let result1 = await task1.value.value
        let result2 = await task2.value.value

        // Only second work executed, first was superseded
        #expect(await counter.value == 1)
        #expect(result1 == .superseded)
        #expect(result2 == .executed(2))
    }

    // MARK: - Sequential Independent Calls

    @Test
    func sequentialCallsWithGapsExecuteIndependently() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)

        // First call
        let task1 = await debouncer.debounce {
            await counter.increment()
            return await counter.value
        }
        await clock.advance(by: .milliseconds(300))
        #expect(await task1.value == .executed(1))
        #expect(await counter.value == 1)

        // Second call after first completed
        let task2 = await debouncer.debounce {
            await counter.increment()
            return await counter.value
        }
        await clock.advance(by: .milliseconds(300))
        #expect(await task2.value == .executed(2))
        #expect(await counter.value == 2)
    }
}

// MARK: - Test Helpers

private actor Counter {
    var value = 0

    func increment() {
        value += 1
    }
}

private actor ResultHolder {
    var value = ""

    func set(_ newValue: String) {
        value = newValue
    }
}
```

### Success Criteria

#### Automated Verification:
- [x] `swift test --filter DebouncerTests` - all tests pass

---

## Phase 3: Add Emission.debounce Extension

### Overview

Add a `debounce(using:)` method on `Emission` that wraps `.perform` effects with debounce logic, using `DebounceResult` to handle superseded work.

### Changes Required

#### 1. Add Emission Extension

**File**: `Sources/UnoArchitecture/Domain/Emission+Debounce.swift` (new file)

```swift
import Foundation

extension Emission {
    /// Debounces this emission using the provided debouncer.
    ///
    /// When applied to a `.perform` emission, the work is debounced - rapid calls
    /// cancel previous pending work and only the last one executes after the quiet period.
    ///
    /// The debouncer returns `DebounceResult<Action?>` which preserves the semantic
    /// difference between:
    /// - `.executed(nil)`: work ran and chose not to emit an action
    /// - `.superseded`: work was cancelled by a newer call
    ///
    /// Both cases result in `nil` at the Emission level (no action to process),
    /// but the distinction is preserved in the debouncer for logging/debugging.
    ///
    /// ```swift
    /// case .searchTextChanged(let query):
    ///     state.query = query
    ///     return .perform {
    ///         let results = await api.search(query)
    ///         return .searchCompleted(results)
    ///     }
    ///     .debounce(using: searchDebouncer)
    /// ```
    ///
    /// - Parameter debouncer: The debouncer to use for timing and coalescing.
    /// - Returns: A debounced emission.
    public func debounce<C: Clock>(
        using debouncer: Debouncer<C, Action?>
    ) -> Emission<Action> where C.Duration: Sendable {
        switch kind {
        case .none:
            return .none

        case .action(let action):
            // Immediate actions pass through unchanged
            return .action(action)

        case .perform(let work):
            return .perform {
                let task = await debouncer.debounce {
                    await work()
                }
                switch await task.value {
                case .executed(let action):
                    return action  // Action? flows through
                case .superseded:
                    return nil     // Superseded work emits no action
                }
            }

        case .observe:
            // Observation streams are not debounced (they're long-lived)
            // For stream debouncing, use AsyncAlgorithms or transform the stream itself
            return self

        case .merge(let emissions):
            return .merge(emissions.map { $0.debounce(using: debouncer) })
        }
    }
}
```

#### 2. Example Usage in Interactor

```swift
struct SearchInteractor: Interactor {
    struct State: Equatable, Sendable {
        var query: String = ""
        var results: [SearchResult] = []
        var isSearching: Bool = false
    }

    enum Action: Sendable {
        case searchTextChanged(String)
        case searchCompleted([SearchResult])
        case searchFailed(Error)
    }

    // Debouncer is held by the interactor for the lifetime of the feature
    private let searchDebouncer: Debouncer<ContinuousClock, Action?>

    init() {
        self.searchDebouncer = Debouncer(for: .milliseconds(300))
    }

    var body: some InteractorOf<Self> { self }

    func interact(state: inout State, action: Action) -> Emission<Action> {
        switch action {
        case .searchTextChanged(let query):
            state.query = query
            state.isSearching = true

            return .perform { [query] in
                do {
                    let results = try await searchAPI.search(query: query)
                    return .searchCompleted(results)
                } catch {
                    return .searchFailed(error)
                }
            }
            .debounce(using: searchDebouncer)

        case .searchCompleted(let results):
            state.isSearching = false
            state.results = results
            return .none

        case .searchFailed:
            state.isSearching = false
            return .none
        }
    }
}
```

### Success Criteria

#### Automated Verification:
- [x] `swift build` compiles successfully
- [x] New unit tests for `Emission.debounce` pass

#### Manual Verification:
- [ ] Example search interactor works correctly with rapid typing

---

## Phase 4: Add Debounce Higher-Order Interactor

### Overview

Implement `Interactors.Debounce` that wraps a child interactor using **effect-level debouncing**. Actions are processed immediately (state changes right away), but the child's emissions are debounced using our existing `Emission.debounce` extension.

### Design Decision: Effect-Level Debouncing

| Aspect | Action-Level | Effect-Level (chosen) |
|--------|--------------|----------------------|
| State changes | Delayed until debounce fires | Immediate |
| Effects | Only last action runs at all | All actions run, only last effect executes |
| Implementation | Complex (hold action, re-send) | Simple (reuses `Emission.debounce`) |
| Use case | Rare | Common - immediate UI, debounced API calls |

**Example (search):**
```swift
// User types "h" → state.query = "h", isSearching = true, API call debounced
// User types "he" → state.query = "he", isSearching = true, previous API call cancelled
// After 300ms → only "he" search executes
```

The user sees their input immediately, but the expensive async work is debounced.

### Changes Required

#### 1. Implement Debounce Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift`

```swift
import Foundation

extension Interactors {
    /// An interactor that debounces the effects of a child interactor.
    ///
    /// Actions are processed immediately through the child (state changes right away),
    /// but the child's emissions are debounced - only the last effect executes after
    /// the debounce duration elapses with no new actions.
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     Interactors.Debounce(for: .milliseconds(300)) {
    ///         SearchInteractor()
    ///     }
    /// }
    /// ```
    ///
    /// ## Behavior
    ///
    /// 1. Action arrives → processed immediately, state changes
    /// 2. Child's emission is debounced
    /// 3. Another action arrives → new emission cancels previous pending effect
    /// 4. After quiet period → last effect executes
    ///
    /// - Note: State changes happen immediately. Only effects are debounced.
    public struct Debounce<C: Clock, Child: Interactor & Sendable>: Interactor, Sendable
    where Child.DomainState: Sendable, Child.Action: Sendable, C.Duration: Sendable {
        public typealias DomainState = Child.DomainState
        public typealias Action = Child.Action

        private let child: Child
        private let debouncer: Debouncer<C, Action?>

        /// Creates a debouncing interactor.
        ///
        /// - Parameters:
        ///   - duration: How long to wait after the last action before executing effects.
        ///   - clock: The clock to use for timing. Inject `TestClock` for testing.
        ///   - child: A closure that returns the child interactor to wrap.
        public init(for duration: C.Duration, clock: C, child: () -> Child) {
            self.child = child()
            self.debouncer = Debouncer(for: duration, clock: clock)
        }

        public var body: some InteractorOf<Self> { self }

        public func interact(state: inout DomainState, action: Action) -> Emission<Action> {
            // Process action immediately - state changes now
            let childEmission = child.interact(state: &state, action: action)
            // Debounce only the effects
            return childEmission.debounce(using: debouncer)
        }
    }
}

extension Interactors.Debounce where C == ContinuousClock {
    /// Creates a debouncing interactor using the continuous clock.
    ///
    /// - Parameters:
    ///   - duration: How long to wait after the last action before executing effects.
    ///   - child: A closure that returns the child interactor to wrap.
    public init(for duration: Duration, child: () -> Child) {
        self.init(for: duration, clock: ContinuousClock(), child: child)
    }
}

/// Convenience typealias for debounced interactors.
public typealias DebounceInteractor<C: Clock & Sendable, Child: Interactor & Sendable> = Interactors.Debounce<C, Child>
    where Child.DomainState: Sendable, Child.Action: Sendable, C.Duration: Sendable
```

### Success Criteria

#### Automated Verification:
- [x] `swift build` compiles successfully
- [x] `swift test --filter DebounceInteractorTests` passes

---

## Phase 5: Uncomment and Update Debounce Tests

### Overview

Update the commented-out `Interactors+DebounceTests.swift` to test effect-level debouncing behavior. Key difference from action-level: **state changes happen immediately**, only effects are debounced.

### Changes Required

#### 1. Update DebounceInteractorTests

**File**: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+DebounceTests.swift`

```swift
import Clocks
import Foundation
import Testing

@testable import UnoArchitecture

@Suite(.serialized)
@MainActor
struct DebounceInteractorTests {

    @Test
    func stateChangesImmediately() async throws {
        let clock = TestClock()

        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            clock: clock
        ) {
            CounterInteractor()
        }

        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: debounced
        )

        #expect(harness.states == [.init(count: 0)])

        // Send action - state changes IMMEDIATELY (effect-level debouncing)
        harness.send(.increment)

        // State already changed
        #expect(harness.states == [.init(count: 0), .init(count: 1)])
    }

    @Test
    func allActionsProcessedImmediately() async throws {
        let clock = TestClock()

        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            clock: clock
        ) {
            CounterInteractor()
        }

        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: debounced
        )

        // Send multiple rapid actions - ALL state changes happen immediately
        harness.send(.increment)
        harness.send(.increment)
        harness.send(.increment)

        // All three increments processed immediately
        #expect(harness.states == [
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3)
        ])
    }

    @Test
    func effectsAreDebounced() async throws {
        let clock = TestClock()
        let effectExecutionCount = Counter()

        // Interactor that returns a .perform effect
        struct EffectInteractor: Interactor, Sendable {
            struct State: Equatable, Sendable {
                var triggerCount: Int = 0
                var effectResult: Int = 0
            }
            enum Action: Sendable, Equatable {
                case trigger
                case effectCompleted(Int)
            }

            let counter: Counter

            var body: some InteractorOf<Self> { self }

            func interact(state: inout State, action: Action) -> Emission<Action> {
                switch action {
                case .trigger:
                    state.triggerCount += 1
                    let count = state.triggerCount
                    return .perform { [counter] in
                        await counter.increment()
                        return .effectCompleted(count)
                    }
                case .effectCompleted(let result):
                    state.effectResult = result
                    return .none
                }
            }
        }

        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            clock: clock
        ) {
            EffectInteractor(counter: effectExecutionCount)
        }

        let harness = InteractorTestHarness(
            initialState: EffectInteractor.State(),
            interactor: debounced
        )

        // Send multiple triggers rapidly
        harness.send(.trigger)
        harness.send(.trigger)
        let task = harness.send(.trigger)

        // All state changes happened immediately
        #expect(harness.currentState.triggerCount == 3)

        // But NO effects have executed yet
        #expect(await effectExecutionCount.value == 0)

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))
        await task.finish()

        // Only ONE effect executed (the last one)
        #expect(await effectExecutionCount.value == 1)

        // Effect result reflects the last trigger
        #expect(harness.currentState.effectResult == 3)
    }

    @Test
    func noneEmissionsPassThrough() async throws {
        let clock = TestClock()

        // CounterInteractor returns .none, should work fine
        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            clock: clock
        ) {
            CounterInteractor()
        }

        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: debounced
        )

        harness.send(.increment)
        harness.send(.decrement)
        harness.send(.increment)

        // All processed immediately since .none emissions pass through
        #expect(harness.currentState.count == 1)
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
```

### Success Criteria

#### Automated Verification:
- [x] `swift test --filter DebounceInteractorTests` - all tests pass

---

## Phase 6: Add Emission.debounce Tests

### Overview

Add comprehensive tests for the `Emission.debounce` extension, verifying that `DebounceResult` semantics are properly handled.

### Changes Required

#### 1. Create Emission+DebounceTests

**File**: `Tests/UnoArchitectureTests/DomainTests/EmissionDebounceTests.swift` (new file)

```swift
import Clocks
import Foundation
import Testing

@testable import UnoArchitecture

@Suite(.serialized)
@MainActor
struct EmissionDebounceTests {

    enum TestAction: Sendable, Equatable {
        case result(Int)
    }

    @Test
    func debounceDelaysPerformEmission() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let emission = Emission<TestAction>.perform {
            .result(42)
        }.debounce(using: debouncer)

        // Extract the work from the emission
        guard case .perform(let work) = emission.kind else {
            Issue.record("Expected .perform emission")
            return
        }

        async let resultTask = work()

        // Advance time
        await clock.advance(by: .milliseconds(300))

        let result = await resultTask
        #expect(result == .result(42))
    }

    @Test
    func debounceCoalescesRapidPerformEmissions() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        // Simulate rapid emissions (like rapid key presses)
        let emission1 = Emission<TestAction>.perform { .result(1) }.debounce(using: debouncer)
        let emission2 = Emission<TestAction>.perform { .result(2) }.debounce(using: debouncer)
        let emission3 = Emission<TestAction>.perform { .result(3) }.debounce(using: debouncer)

        guard case .perform(let work1) = emission1.kind,
              case .perform(let work2) = emission2.kind,
              case .perform(let work3) = emission3.kind else {
            Issue.record("Expected .perform emissions")
            return
        }

        // Start all three concurrently (simulating rapid calls)
        async let r1 = work1()
        async let r2 = work2()
        async let r3 = work3()

        await clock.advance(by: .milliseconds(300))

        let results = await [r1, r2, r3]

        // First two should be nil (superseded), third should have value
        #expect(results[0] == nil)
        #expect(results[1] == nil)
        #expect(results[2] == .result(3))
    }

    @Test
    func executedNilIsDistinctFromSuperseded() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        // First emission: work that intentionally returns nil
        let emission1 = Emission<TestAction>.perform {
            nil  // Intentionally no action
        }.debounce(using: debouncer)

        guard case .perform(let work1) = emission1.kind else {
            Issue.record("Expected .perform emission")
            return
        }

        async let r1 = work1()
        await clock.advance(by: .milliseconds(300))

        // Work executed and returned nil - this is .executed(nil) at debouncer level
        // but becomes nil at Emission level (no action to emit)
        let result1 = await r1
        #expect(result1 == nil)

        // Second emission: work that gets superseded
        let emission2 = Emission<TestAction>.perform { .result(1) }.debounce(using: debouncer)
        let emission3 = Emission<TestAction>.perform { .result(2) }.debounce(using: debouncer)

        guard case .perform(let work2) = emission2.kind,
              case .perform(let work3) = emission3.kind else {
            Issue.record("Expected .perform emissions")
            return
        }

        async let r2 = work2()
        async let r3 = work3()
        await clock.advance(by: .milliseconds(300))

        // work2 was superseded (.superseded at debouncer level)
        // work3 executed (.executed(.result(2)) at debouncer level)
        let results = await [r2, r3]
        #expect(results[0] == nil)  // Superseded
        #expect(results[1] == .result(2))  // Executed
    }

    @Test
    func noneEmissionPassesThrough() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let emission = Emission<TestAction>.none.debounce(using: debouncer)

        guard case .none = emission.kind else {
            Issue.record("Expected .none emission")
            return
        }
    }

    @Test
    func actionEmissionPassesThrough() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let emission = Emission<TestAction>.action(.result(42)).debounce(using: debouncer)

        guard case .action(let action) = emission.kind else {
            Issue.record("Expected .action emission")
            return
        }

        #expect(action == .result(42))
    }
}
```

### Success Criteria

#### Automated Verification:
- [x] `swift test --filter EmissionDebounceTests` - all tests pass

---

## Testing Strategy

### Unit Tests

**Debouncer Tests** (`DebouncerTests.swift`):
- `.executed(T)` returned after debounce duration
- Superseded calls return `.superseded`
- `.executed(nil)` is distinct from `.superseded` (key semantic test)
- Only last work closure executes
- Timer reset on new call
- External cancellation returns `.superseded`

**Emission.debounce Tests** (`EmissionDebounceTests.swift`):
- `.perform` effects are debounced
- `.none` passes through
- `.action` passes through
- `.observe` passes through (not debounced)
- `.merge` debounces child perform emissions

**Debounce Interactor Tests** (`Interactors+DebounceTests.swift`):
- Actions delayed by debounce duration
- Rapid actions coalesced
- Only last action processed
- Works with TestClock for deterministic testing

### Integration Tests

Test with `InteractorTestHarness`:
- Search scenario: rapid key presses → single search
- Form validation: rapid input → single validation

### Manual Testing Steps

1. Create sample search UI with debounced interactor
2. Type rapidly in search field
3. Verify only one API call made
4. Verify final results match last query

---

## Performance Considerations

### Task Efficiency

The current design creates a new `Task` per `debounce` call. For rapid calls (e.g., 60 keystrokes/second), this creates 60 tasks per second, though 59 are immediately cancelled.

**Alternative (More Complex)**: Single persistent task with work replacement:
```swift
actor Debouncer<C: Clock, T: Sendable> {
    private var pendingWork: (@Sendable () async -> T)?
    private var workerTask: Task<Void, Never>?

    func debounce(_ work: @escaping @Sendable () async -> T) async -> T? {
        pendingWork = work

        if workerTask == nil {
            workerTask = Task { [weak self] in
                while let self {
                    // Wait for debounce duration
                    // Execute pendingWork if still set
                    // Reset if new work arrived during execution
                }
            }
        }
        // Signal the worker task...
    }
}
```

**Recommendation**: Start with simple approach (new task per call). Profile in real usage. The cancellation overhead is minimal and the code is much simpler.

### Memory

- `Debouncer` actor is lightweight (~40 bytes)
- Each pending `Task` is small (~200 bytes)
- Cancelled tasks are immediately deallocated

No memory concerns for typical usage.

---

## References

### Web Research

- [TCA Debounce Implementation](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Effects/Debounce.swift) - Cancel-in-flight pattern
- [TCA Cancellation](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Effects/Cancellation.swift) - withTaskCancellation
- [Swift Async Algorithms Debounce](https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Debounce.md) - Official Apple debounce
- [Point-Free Episode 103](https://www.pointfree.co/episodes/ep103-a-tour-of-the-composable-architecture-part-4) - TCA debounce explanation
- [Debouncing with Swift Concurrency](https://sideeffect.io/posts/2023-01-11-regulate/) - Custom implementation patterns

### Internal Documentation

- Emission Migration Plan: `thoughts/shared/plans/2026-01-04_emission-action-migration.md`
- Current Emission: `Sources/UnoArchitecture/Domain/Emission.swift`
- Current Debouncer: `Sources/UnoArchitecture/Internal/Debouncer.swift`

---

## Summary

| Phase | Description | Key Files |
|-------|-------------|-----------|
| 1 | Add DebounceResult type and update Debouncer | `DebounceResult.swift`, `Debouncer.swift` |
| 2 | Update Debouncer tests | `DebouncerTests.swift` |
| 3 | Add Emission.debounce extension | `Emission+Debounce.swift` |
| 4 | Add Debounce interactor | `Debounce.swift` |
| 5 | Update Debounce interactor tests | `Interactors+DebounceTests.swift` |
| 6 | Add Emission.debounce tests | `EmissionDebounceTests.swift` |

**Total New Files**: 3 (`DebounceResult.swift`, `Emission+Debounce.swift`, `EmissionDebounceTests.swift`)
**Modified Files**: 3 (`Debouncer.swift`, `Debounce.swift`, `DebouncerTests.swift`, `Interactors+DebounceTests.swift`)
