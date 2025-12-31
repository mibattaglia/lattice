# Interactor System Migration: Combine to AsyncStream/AsyncSequence

Last Updated: 2025-12-30

## Executive Summary

This document outlines the migration of the UnoArchitecture Interactor system from Combine to AsyncStream/AsyncSequence. The current system uses Combine's `Publisher` protocol as the foundation for reactive state management, with custom operators like `.feedback()` enabling stateful transformations. The migration will modernize the architecture to use Swift's native async/await primitives and AsyncSequence, making the codebase more idiomatic, easier to understand, and aligned with Swift 6's concurrency model.

**Key decisions:**
- Replace `AnyPublisher<State, Never>` with `AsyncStream<State>` as the core emission type
- Leverage swift-async-algorithms for operator composition (merge, debounce, combineLatest, flatMap)
- Maintain the result-builder API and declarative composition patterns
- Migrate all at once (library is under initial development, no incremental migration needed)
- First-class testing infrastructure with `TestClock` and `AsyncStreamRecorder`
- Use `@MainActor` isolation for `Interactor` protocol and primitives
- Use TCA-inspired `Send` callback pattern for effects to emit state updates

The migration replaces the entire Combine-based Interactor system with AsyncStream equivalents in a single pass.

---

## Context & Requirements

### Current Architecture Overview

The Interactor system is built on these key components:

1. **`Interactor` Protocol**: Core abstraction that transforms `AnyPublisher<Action, Never>` → `AnyPublisher<DomainState, Never>`
2. **`Interact` Primitive**: Stateful reducer that uses `.feedback()` operator to handle imperative state transitions and async effects via `Emission`
3. **`Emission` Type**: Descriptor for how to emit state (`.state`, `.perform`, `.observe`)
4. **Combine Operators**: Uses `flatMap`, `merge`, `debounce`, `filter`, `handleEvents` for composition
5. **Result Builder**: `InteractorBuilder` enables declarative DSL with control flow
6. **Higher-Order Interactors**: `Merge`, `MergeMany`, `Debounce`, `When` compose child interactors
7. **Feedback Loop**: Custom `.feedback()` operator manages state via `CurrentValueSubject` and effect cancellables

### Requirements for Migration

1. **Maintain API Surface**: Result-builder DSL and declarative composition must remain intact
2. **Support Async Effects**: `.perform { async work }` pattern must continue working
3. **Support Observe Pattern**: `.observe { dynamicState in stream }` must work with AsyncStream
4. **Enable Operator Composition**: Need equivalents for merge, debounce, filter, map, flatMap
5. **First-Class Testing**: `TestClock` for time control, `AsyncStreamRecorder` for emission capture
6. **Performance**: AsyncStream should not degrade performance vs. Combine
7. **Cancellation**: Task cancellation must replace Combine's AnyCancellable pattern
8. **Type Safety**: Maintain strong typing throughout the pipeline

---

## Existing Codebase Analysis

### Current Combine Usage Patterns

**Core Operators Used:**
- `flatMap` - Sequential async work, child interactor composition (Merge, MergeMany)
- `merge(with:)` - Combining multiple streams (When interactor)
- `debounce(for:scheduler:)` - Debounce interactor
- `filter` - Filtering child actions in When interactor
- `handleEvents` - Side effects for routing actions in When interactor
- `sink` - Terminal subscription for effect handling
- `eraseToAnyPublisher()` - Type erasure throughout

**Custom Combine Extensions:**
- `.feedback()` - Stateful reducer with effect handling (central to `Interact`)
- `.interact(with:)` - Convenience for feeding publisher through interactor
- `Publishers.Async` - Custom publisher that wraps async work

**Subject Usage:**
- `CurrentValueSubject` - State management in feedback loop (1 usage)
- `PassthroughSubject` - Action routing in When interactor, StreamBuilder (3 usages)

**Critical Patterns:**

1. **Feedback Loop Pattern** (`Combine+FeedbackLoop.swift`):
   ```swift
   func feedback<State>(
       initialState: State,
       handler: (inout State, Output) -> Emission<State>
   ) -> Publishers.HandleEvents<CurrentValueSubject<State, Never>>
   ```
   - Uses `CurrentValueSubject` to hold state
   - Handles `.state`, `.perform`, and `.observe` emissions
   - Manages effect cancellables in a Set
   - This is the **core complexity** to migrate

2. **When Interactor Child Embedding**:
   - Uses `PassthroughSubject` to route child actions
   - Merges child state changes back as parent actions
   - Relies on `filter` and `handleEvents` for action routing

3. **MergeMany Back-Pressure**:
   - Uses `flatMap(maxPublishers: .max(1))` for serialization
   - Ensures deterministic ordering across multiple children

### Architectural Strengths to Preserve

1. **Declarative Composition**: Result-builder enables clear, composable interactor trees
2. **Strong Typing**: Generic constraints ensure type safety across transformations
3. **Effect Management**: `Emission` provides clear separation of sync vs. async state changes
4. **Testability**: Dependency injection (schedulers) enables deterministic testing
5. **Modularity**: Higher-order interactors compose cleanly

### Problems with Current Approach

1. **Learning Curve**: Combine's `Publisher` model is complex for newcomers
2. **Verbosity**: Type erasure (`eraseToAnyPublisher()`) required everywhere
3. **Non-Idiomatic**: Combine is semi-deprecated in favor of async/await
4. **Debugging**: Combine chains are hard to debug (no stack traces through publishers)
5. **Resource Management**: `AnyCancellable` storage patterns are error-prone
6. **Limited Swift 6 Support**: Combine predates structured concurrency

---

## Architectural Approaches

### Approach 1: Direct AsyncStream Replacement (Recommended)

**Overview**: Replace `AnyPublisher<T, Never>` with `AsyncStream<T>` throughout, leveraging swift-async-algorithms for operators.

**Key Components**:
- `Interactor.interact(_:)` returns `AsyncStream<DomainState>` instead of `AnyPublisher`
- Rewrite `.feedback()` as async function that yields to stream
- Use swift-async-algorithms for merge, debounce, flatMap, combineLatest
- Use `Task` for cancellation instead of `AnyCancellable`

**Patterns Used**:
- `AsyncStream` for state emission
- `AsyncChannel` for back-pressure (When interactor child routing)
- swift-async-algorithms operators (not manual reimplementation)

**Pros**:
- Simplest mental model (imperative async code)
- Native Swift concurrency patterns
- swift-async-algorithms provides battle-tested operators (flatMap, merge, debounce, etc.)
- Better debugging (stack traces through async calls)
- Clean codebase without adapter complexity

**Cons**:
- Requires rewriting all interactor implementations at once
- swift-async-algorithms is less mature than Combine (but actively maintained by Apple)
- Potential performance differences (need benchmarking)

**Trade-offs**:
- Simplicity vs. maturity: Gain simplicity, swift-async-algorithms provides mature operators
- Performance: Need to validate AsyncStream performance characteristics
- Migration cost: Higher upfront cost, but cleaner result

---

### Approach 2: AsyncSequence Protocol-Oriented Design

**Overview**: Define `Interactor` to work with `any AsyncSequence<State>`, use swift-async-algorithms for operator composition.

**Key Components**:
- `Interactor.interact(_:)` returns `some AsyncSequence<DomainState>`
- Leverage swift-async-algorithms operators (merge, debounce, combineLatest)
- Use opaque result types to avoid type erasure
- Feedback loop implemented via custom `AsyncFeedbackSequence`

**Patterns Used**:
- Protocol-oriented design with AsyncSequence conformance
- Opaque result types (`some AsyncSequence`) to avoid type erasure
- swift-async-algorithms for operator composition
- Custom `AsyncFeedbackSequence` type for stateful reduction

**Pros**:
- Leverages Apple's official async-algorithms library
- Protocol-oriented approach maintains flexibility
- Opaque types eliminate need for type erasure
- Can compose with any AsyncSequence (not just AsyncStream)

**Cons**:
- More complex type system (some AsyncSequence constraints)
- Swift compiler limitations with opaque types in protocols
- Potential performance overhead from protocol dispatch
- Still requires custom feedback sequence implementation

**Trade-offs**:
- Flexibility vs. complexity: Gain protocol flexibility, add type complexity
- Reusability: Can integrate with any AsyncSequence
- Compiler limitations: May hit Swift 5.9+ limitations with opaque types

---

### Approach 3: Hybrid Adapter Pattern

**Overview**: Create an adapter layer that bridges Combine and AsyncStream, enabling incremental migration.

**Key Components**:
- New `AsyncInteractor` protocol alongside existing `Interactor`
- Adapter utilities: `publisher.values` → AsyncStream, `asyncStream.publisher()` → Publisher
- Dual implementation of primitives (Interact → AsyncInteract)
- Gradual migration path: convert leaf interactors first, then higher-order ones
- Testing infrastructure supports both paradigms

**Patterns Used**:
- Adapter pattern for bridging Combine ↔ AsyncStream
- Parallel type hierarchies during migration
- Provider pattern for creating test schedulers (both Combine and AsyncStream)
- Feature flags to enable new implementations

**Pros**:
- Incremental migration (feature-by-feature)
- Both APIs coexist during transition
- Lower risk (can roll back individual features)
- Team can learn AsyncStream patterns gradually
- Testing infrastructure remains stable

**Cons**:
- Temporary code duplication (two implementations)
- Adapter overhead during migration period
- More complex mental model during transition
- Need to maintain both paths until migration complete

**Trade-offs**:
- Migration safety vs. code duplication: Gain safety, accept temporary duplication
- Team velocity: Lower risk enables faster iteration
- Maintenance burden: Higher during migration, lower after completion

---

## Recommended Approach: Direct AsyncStream Replacement

**Rationale**: Since the library is under initial development, a complete migration is preferred over incremental approaches:

1. **Clean codebase**: No adapter layer complexity or dual implementations
2. **Consistent patterns**: All interactors use the same AsyncStream-based approach
3. **Simpler testing**: One testing paradigm (AsyncStream) instead of two
4. **No technical debt**: No temporary bridges to maintain and eventually remove
5. **Faster completion**: Single focused effort vs. prolonged dual-system maintenance

**Why not incremental**: The Strangler Fig Pattern is valuable for production systems with active users. For a library under development, the overhead of maintaining adapters and dual implementations outweighs the benefits.

**Migration scope**: Replace all Combine-based types in a single pass:
- `Interactor` → `AsyncInteractor` (then rename back to `Interactor`)
- `Emission` → `AsyncEmission` (then rename back to `Emission`)
- `Interact` → `AsyncInteract` (then rename back to `Interact`)
- All higher-order interactors (Merge, Debounce, When, etc.)

---

## Detailed Technical Design

### System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         SwiftUI View                         │
│                  (sends ViewEvent, observes ViewState)       │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                         ViewModel                            │
│   • Subscribes to AsyncStream<ViewState>                     │
│   • Sends actions via Task-based lifecycle                   │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                    Interactor Layer                          │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                     Interactor                         │   │
│  │  • interact(AsyncStream<Action>) -> AsyncStream<State> │   │
│  │  • Composed via InteractorBuilder                      │   │
│  └──────────────────────────────────────────────────────┘   │
│                            │                                  │
│                            ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Higher-Order Interactors                  │   │
│  │  • Merge, MergeMany - Combine streams                  │   │
│  │  • Debounce - Time-based filtering                     │   │
│  │  • When - Child interactor embedding                   │   │
│  │  • Conditional - if/else branching                     │   │
│  └──────────────────────────────────────────────────────┘   │
│                            │                                  │
│                            ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                      Interact                          │   │
│  │  • Core primitive with feedback loop                   │   │
│  │  • Handles Emission (.state, .perform, .observe)       │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                   Domain/Services                            │
│              (async functions, repositories)                 │
└─────────────────────────────────────────────────────────────┘
```

### Pattern Selection & Justification

**Patterns Used**:

1. **Strategy Pattern**: Different emission strategies (state, perform, observe)
   - **Why**: Preserves existing `Emission.Kind` pattern from Combine version
   - **Where**: `Emission.Kind` enum

2. **Provider Pattern**: Injectable clocks for testing
   - **Why**: Maintain testability with deterministic time control
   - **Where**: `Clock` protocol for time-based operations (Debounce, Throttle)

3. **Builder Pattern**: Result builder for declarative composition
   - **Why**: Key API surface that makes interactors pleasant to use
   - **Where**: `InteractorBuilder`

4. **MainActor + StateBox Pattern**: Thread-safe state management on main thread
   - **Why**: All UI state mutations should occur on main thread; simpler than actor isolation
   - **Where**: `StateBox` class in `Interact` primitive, `@MainActor` on protocol

5. **Send Callback Pattern**: TCA-inspired effect-to-state communication
   - **Why**: Enables background work to emit state updates cleanly without `Task.detached`
   - **Where**: `Send<State>` struct used in `.perform` and `.observe` emissions

6. **Dynamic Member Lookup**: Convenient state access in observe handlers
   - **Why**: Mirrors existing `DynamicState` pattern from Combine version
   - **Where**: `DynamicState` struct

**Existing Patterns Preserved**:
- Result builder DSL (`@InteractorBuilder`)
- Higher-order interactor composition (Merge, Debounce, When)
- Emission-based effect handling (`.state`, `.perform`, `.observe`)
- Generic associated types for State/Action
- `DynamicState` for observe pattern

**New Patterns Introduced**:
- Task-based cancellation instead of AnyCancellable
- AsyncStream-based state emission instead of Publisher
- `@MainActor` isolation with `StateBox` for thread-safe state
- `Send` callback pattern for effect-to-state communication
- swift-async-algorithms operators (merge, debounce, flatMap, etc.)
- `TestClock` for deterministic time-based testing

---

### Composition & Extensibility

**How it composes**:
- `Interactor` protocol defines the transformation contract
- Higher-order interactors compose via `InteractorBuilder` result builder
- Type system ensures compile-time safety for State/Action alignment

**Extension points**:
1. **Custom operators**: Extend `AsyncSequence` with domain-specific transformations
2. **Emission types**: Add new `Emission.Kind` cases for new effect patterns
3. **Higher-order interactors**: Create new interactor combinators (e.g., `Throttle`, `Retry`)
4. **Custom streams**: Use swift-async-algorithms to create domain-specific stream transformations

**Avoiding enumeration**:
- No hardcoded if/else for interactor types
- Generic constraints handle type relationships
- Result builder handles composition without manual type checking

---

### Progressive Disclosure

**Public API - Simple**:
```swift
@Interactor<State, Action>
struct MyInteractor {
    var body: some InteractorOf<Self> {
        Interact(initialValue: .loading) { state, action in
            // Simple state transitions
            return .state
        }
    }
}
```

**Advanced API - Power Users**:
```swift
// Custom async sequence operators
extension InteractorOf<MyInteractor> {
    func withCustomBackpressure() -> some Interactor<State, Action> {
        // Advanced stream manipulation
    }
}

// Direct interact() implementation for complex cases
func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
    // Manual stream handling with swift-async-algorithms
}
```

**Internal complexity**:
- Task lifecycle management abstracted away
- swift-async-algorithms operators wrapped in familiar APIs

---

## Core Type Definitions

### Interactor Protocol

```swift
import AsyncAlgorithms

/// A type that transforms a stream of actions into a stream of domain state.
///
/// Interactors are the core building blocks for business logic. They receive
/// actions from the UI layer and emit state changes that drive view updates.
///
/// Interactors are `@MainActor` isolated to ensure all state mutations occur
/// on the main thread. Background work is handled via the `Send` callback pattern,
/// which automatically hops back to the main actor when emitting state.
@MainActor
public protocol Interactor<DomainState, Action> {
    associatedtype DomainState: Sendable
    associatedtype Action
    associatedtype Body: Interactor

    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    /// Transforms the upstream action stream into a stream of domain state.
    func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState>
}

extension Interactor where Body: Interactor<DomainState, Action> {
    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState> {
        self.body.interact(upstream)
    }
}

public typealias InteractorOf<I: Interactor> = Interactor<I.DomainState, I.Action>

public struct AnyInteractor<State: Sendable, Action>: Interactor {
    private let interactFunc: @MainActor (AsyncStream<Action>) -> AsyncStream<State>

    public init<I: Interactor>(_ base: I) where I.DomainState == State, I.Action == Action {
        self.interactFunc = base.interact(_:)
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        interactFunc(upstream)
    }
}
```

### Send Type

```swift
/// A callback for emitting state updates from effects.
///
/// `Send` is `@MainActor` isolated, ensuring all state mutations occur on the
/// main thread. When called from a non-isolated async context (like an effect
/// closure), Swift automatically handles the actor hop.
///
/// This pattern is inspired by TCA's (The Composable Architecture) `Send` type.
///
/// Example:
/// ```swift
/// return .perform { send in
///     let data = await api.fetchData()
///     await send(State(data: data, isLoading: false))
/// }
/// ```
@MainActor
public struct Send<State: Sendable>: Sendable {
    private let yield: @MainActor (State) -> Void

    init(_ yield: @escaping @MainActor (State) -> Void) {
        self.yield = yield
    }

    /// Emits a new state if the current task is not cancelled.
    public func callAsFunction(_ state: State) {
        guard !Task.isCancelled else { return }
        yield(state)
    }
}
```

### StateBox Type

```swift
/// Holds mutable state accessible from effect callbacks.
///
/// `StateBox` is `@MainActor` isolated for thread safety. Unlike an actor,
/// it provides synchronous access to state within the main actor context.
@MainActor
final class StateBox<State>: @unchecked Sendable {
    var value: State

    init(_ initial: State) {
        self.value = initial
    }
}
```

### DynamicState Type

```swift
/// A type that provides **read-only** dynamic member lookup access to the current state
/// within an `observe` emission handler.
///
/// State access is asynchronous because it reads from actor-isolated storage,
/// ensuring thread-safe access to the latest value.
///
/// Example:
/// ```swift
/// return .observe { state in
///     AsyncStream { continuation in
///         let task = Task {
///             for await event in externalStream {
///                 let current = await state.someProperty
///                 continuation.yield(State(updated: current, event: event))
///             }
///         }
///         continuation.onTermination = { _ in task.cancel() }
///     }
/// }
/// ```
@dynamicMemberLookup
public struct DynamicState<State> {
    private let getCurrentState: @Sendable () async -> State

    init(getCurrentState: @escaping @Sendable () async -> State) {
        self.getCurrentState = getCurrentState
    }

    /// Returns the value at the given key path of the underlying state.
    public subscript<T>(dynamicMember keyPath: KeyPath<State, T>) -> T {
        get async {
            await getCurrentState()[keyPath: keyPath]
        }
    }

    /// Returns the full current state value.
    public var current: State {
        get async {
            await getCurrentState()
        }
    }
}

// DynamicState is always Sendable because it only holds a @Sendable closure
extension DynamicState: Sendable {}
```

### Emission Type

```swift
/// A descriptor that tells an Interactor how to emit domain state.
///
/// Emission provides three strategies for state changes:
/// - `.state`: Emit the current state immediately (synchronous)
/// - `.perform`: Execute async work and emit state via `Send` callback
/// - `.observe`: Subscribe to an ongoing stream of state changes via `Send` callback
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        /// Immediately forward state as-is.
        case state

        /// Execute an asynchronous unit of work and emit state via the `Send` callback.
        /// The closure runs on the cooperative thread pool (NOT main actor).
        /// Use `await currentState.current` to read the latest state (hops to MainActor).
        /// Call `await send(newState)` to emit state updates.
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)

        /// Observe a stream, emitting state for each element via the `Send` callback.
        /// The closure runs on the cooperative thread pool.
        /// Use `await currentState.current` to read the latest state (hops to MainActor).
        /// Call `await send(newState)` to emit state updates.
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)
    }

    let kind: Kind

    /// Creates an immediate state emission.
    public static var state: Emission {
        Emission(kind: .state)
    }

    /// Creates a perform emission that executes the given asynchronous work.
    ///
    /// The work closure runs on the cooperative thread pool (background).
    /// Use `await currentState.current` to read the latest state (automatically hops to MainActor).
    /// Use `await send(state)` to emit state updates back to the main actor.
    ///
    /// Example:
    /// ```swift
    /// return .perform { currentState, send in
    ///     do {
    ///         let data = try await api.fetchData()
    ///         let existing = await currentState.items  // Read fresh state
    ///         await send(State(items: existing + [data], isLoading: false))
    ///     } catch {
    ///         await send(State(error: error, isLoading: false))
    ///     }
    /// }
    /// ```
    public static func perform(
        _ work: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .perform(work: work))
    }

    /// Creates an observe emission that iterates an external stream.
    ///
    /// The closure runs on the cooperative thread pool. Use `currentState.current`
    /// to access the latest state, and `await send(state)` to emit updates.
    ///
    /// Example:
    /// ```swift
    /// return .observe { currentState, send in
    ///     for await event in websocketStream {
    ///         let current = await currentState.current
    ///         var items = current.items
    ///         items.append(event)
    ///         await send(State(items: items, isConnected: true))
    ///     }
    /// }
    /// ```
    public static func observe(
        _ stream: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .observe(stream: stream))
    }
}
```

### Interact Primitive

```swift
import AsyncAlgorithms

/// The core building block for stateful interactors.
///
/// `Interact` maintains state and processes actions through a handler that returns
/// `Emission` descriptors. This is the AsyncStream equivalent of a Combine feedback loop.
///
/// The `@MainActor` isolation ensures all state mutations occur on the main thread.
/// Background work is handled via the `Send` callback pattern, which automatically
/// hops back to the main actor when emitting state.
///
/// Example:
/// ```swift
/// Interact(initialValue: State()) { state, action in
///     switch action {
///     case .increment:
///         state.count += 1
///         return .state
///     case .fetchData:
///         return .perform { currentState, send in
///             let data = await api.fetch()
///             let existing = await currentState.items  // Read fresh state
///             await send(State(items: existing + [data]))
///         }
///     }
/// }
/// ```
@MainActor
public struct Interact<State: Sendable, Action>: Interactor {
    public typealias Handler = @MainActor (inout State, Action) -> Emission<State>

    private let initialValue: State
    private let handler: Handler

    public init(
        initialValue: State,
        handler: @escaping Handler
    ) {
        self.initialValue = initialValue
        self.handler = handler
    }

    public var body: some Interactor<State, Action> {
        self
    }

    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                let stateBox = StateBox(initialValue)
                var effectTasks: [Task<Void, Never>] = []

                // Create the Send callback - this is @MainActor
                let send = Send<State> { newState in
                    stateBox.value = newState
                    continuation.yield(newState)
                }

                // Emit initial state
                continuation.yield(stateBox.value)

                for await action in upstream {
                    // Handle action (runs on main actor)
                    var state = stateBox.value
                    let emission = handler(&state, action)
                    stateBox.value = state

                    switch emission.kind {
                    case .state:
                        continuation.yield(state)

                    case .perform(let work):
                        // Regular Task - closure is NOT @MainActor
                        // Runs on cooperative thread pool automatically
                        // DynamicState reads hop to MainActor for synchronization
                        let dynamicState = DynamicState {
                            await MainActor.run { stateBox.value }
                        }
                        let effectTask = Task {
                            await work(dynamicState, send)
                        }
                        effectTasks.append(effectTask)

                    case .observe(let streamWork):
                        // Same pattern as .perform - DynamicState provides synchronized reads
                        let dynamicState = DynamicState {
                            await MainActor.run { stateBox.value }
                        }
                        let effectTask = Task {
                            await streamWork(dynamicState, send)
                        }
                        effectTasks.append(effectTask)
                    }
                }

                // Cleanup on upstream completion
                effectTasks.forEach { $0.cancel() }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
```

### Higher-Order Interactors

#### Merge

```swift
extension Interactors {
    /// Merges two interactors, broadcasting actions to both and merging their state emissions.
    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor {
        private let i0: I0
        private let i1: I1

        public init(_ i0: I0, _ i1: I1) {
            self.i0 = i0
            self.i1 = i1
        }

        public var body: some Interactor<I0.DomainState, I0.Action> { self }

        public func interact(_ upstream: AsyncStream<I0.Action>) -> AsyncStream<I0.DomainState> {
            AsyncStream { continuation in
                let task = Task {
                    // Create a channel for broadcasting actions to both interactors
                    let (actionStream0, actionContinuation0) = AsyncStream<I0.Action>.makeStream()
                    let (actionStream1, actionContinuation1) = AsyncStream<I0.Action>.makeStream()

                    let task0 = Task {
                        for await state in i0.interact(actionStream0) {
                            continuation.yield(state)
                        }
                    }

                    let task1 = Task {
                        for await state in i1.interact(actionStream1) {
                            continuation.yield(state)
                        }
                    }

                    // Broadcast upstream actions to both interactors
                    for await action in upstream {
                        actionContinuation0.yield(action)
                        actionContinuation1.yield(action)
                    }

                    actionContinuation0.finish()
                    actionContinuation1.finish()
                    await task0.value
                    await task1.value
                    continuation.finish()
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        }
    }
}
```

#### Debounce

```swift
import AsyncAlgorithms

extension Interactors {
    /// Debounces actions before passing them to a child interactor.
    public struct Debounce<C: Clock, Child: Interactor>: Interactor {
        public typealias DomainState = Child.DomainState
        public typealias Action = Child.Action

        private let child: Child
        private let duration: C.Duration
        private let clock: C

        public init(for duration: C.Duration, clock: C, child: () -> Child) {
            self.duration = duration
            self.clock = clock
            self.child = child()
        }

        public var body: some InteractorOf<Self> { self }

        public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState> {
            let debouncedStream = AsyncStream { continuation in
                let task = Task {
                    for await action in upstream.debounce(for: duration, clock: clock) {
                        continuation.yield(action)
                    }
                    continuation.finish()
                }

                continuation.onTermination = { _ in
                    task.cancel()
                }
            }

            return child.interact(debouncedStream)
        }
    }
}

// Convenience initializer using ContinuousClock
extension Interactors.Debounce where C == ContinuousClock {
    public init(for duration: Duration, child: () -> Child) {
        self.init(for: duration, clock: ContinuousClock(), child: child)
    }
}

public typealias DebounceInteractor<C: Clock, Child: Interactor> = Interactors.Debounce<C, Child>
```

#### When (Child Embedding)

```swift
import CasePaths

extension Interactor {
    /// Embeds a child interactor that handles a subset of actions and state.
    public func when<ChildState, ChildAction, Child: Interactor>(
        stateIs toChildState: WritableKeyPath<DomainState, ChildState>,
        actionIs toChildAction: CaseKeyPath<Action, ChildAction>,
        stateAction toStateAction: CaseKeyPath<Action, ChildState>,
        @InteractorBuilder<ChildState, ChildAction> run child: () -> Child
    ) -> Interactors.When<Self, Child>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.When(
            parent: self,
            toChildState: .keyPath(toChildState),
            toChildAction: AnyCasePath(toChildAction),
            toStateAction: AnyCasePath(toStateAction),
            child: child()
        )
    }
}

extension Interactors {
    /// Routes actions between parent and child interactors.
    public struct When<Parent: Interactor, Child: Interactor>: Interactor {
        public typealias DomainState = Parent.DomainState
        public typealias Action = Parent.Action

        enum StatePath {
            case keyPath(WritableKeyPath<Parent.DomainState, Child.DomainState>)
            case casePath(AnyCasePath<Parent.DomainState, Child.DomainState>)
        }

        let parent: Parent
        let toChildState: StatePath
        let toChildAction: AnyCasePath<Parent.Action, Child.Action>
        let toStateAction: AnyCasePath<Parent.Action, Child.DomainState>
        let child: Child

        public var body: some Interactor<DomainState, Action> { self }

        public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState> {
            AsyncStream { continuation in
                let task = Task {
                    // AsyncChannel provides back-pressure for child actions
                    let childActionChannel = AsyncChannel<Child.Action>()

                    // Task 1: Process child actions through child interactor
                    let childTask = Task {
                        for await childState in child.interact(childActionChannel) {
                            // Convert child state changes to parent actions
                            let parentAction = toStateAction.embed(childState)
                            // Route back to parent (implementation detail)
                        }
                    }

                    // Task 2: Filter and route parent actions
                    let parentTask = Task {
                        for await action in upstream {
                            if let childAction = toChildAction.extract(from: action) {
                                await childActionChannel.send(childAction)
                            } else {
                                // Pass non-child actions to parent
                                for await state in parent.interact(AsyncStream { c in
                                    c.yield(action)
                                    c.finish()
                                }) {
                                    continuation.yield(state)
                                }
                            }
                        }
                    }

                    await parentTask.value
                    childTask.cancel()
                    continuation.finish()
                }

                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
    }
}
```

---

### Testing Architecture

Testing is a first-class concern. The architecture provides comprehensive testing utilities that make async interactor tests as ergonomic as Combine tests.

**Core Testing Principles**:
1. **Deterministic time**: Injectable `Clock` protocol replaces scheduler-based time
2. **Controllable streams**: `AsyncStream.makeStream()` for test action sources
3. **Emission recording**: `AsyncStreamRecorder` captures all state emissions
4. **Assertion helpers**: Domain-specific matchers for common patterns

---

#### TestClock Implementation

```swift
import Foundation

/// A controllable clock for deterministic testing of time-based operations.
///
/// Usage:
/// ```swift
/// let clock = TestClock()
/// let debounced = upstream.debounce(for: .seconds(1), clock: clock)
///
/// // Send action, advance time, verify emission
/// actionContinuation.yield(.search("query"))
/// await clock.advance(by: .seconds(1))
/// // Now debounce fires
/// ```
public actor TestClock: Clock {
    public typealias Duration = Swift.Duration
    public typealias Instant = TestInstant

    private var _now: TestInstant
    private var sleepers: [(deadline: TestInstant, continuation: CheckedContinuation<Void, Never>)] = []

    public init(now: TestInstant = TestInstant(offset: .zero)) {
        self._now = now
    }

    public var now: TestInstant {
        _now
    }

    public var minimumResolution: Duration {
        .nanoseconds(1)
    }

    public func sleep(until deadline: TestInstant, tolerance: Duration?) async throws {
        if deadline <= _now {
            return
        }

        await withCheckedContinuation { continuation in
            sleepers.append((deadline: deadline, continuation: continuation))
            sleepers.sort { $0.deadline < $1.deadline }
        }
    }

    /// Advances the clock by the given duration, waking any sleepers whose deadline has passed.
    public func advance(by duration: Duration) async {
        let newNow = _now.advanced(by: duration)
        _now = newNow

        // Wake sleepers whose deadline has passed
        while let first = sleepers.first, first.deadline <= newNow {
            sleepers.removeFirst()
            first.continuation.resume()
            await Task.yield()  // Allow woken tasks to run
        }
    }

    /// Runs until all pending sleepers have been woken.
    public func runToCompletion() async {
        while let last = sleepers.last {
            await advance(by: last.deadline.offset - _now.offset)
        }
    }
}

/// A point in time for TestClock.
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

#### AsyncStreamRecorder

```swift
/// Records all emissions from an AsyncStream for test assertions.
///
/// Usage:
/// ```swift
/// let recorder = AsyncStreamRecorder<State>()
/// let stateStream = interactor.interact(actionStream)
///
/// await recorder.record(stateStream)
///
/// actionContinuation.yield(.increment)
/// await recorder.waitForEmissions(count: 2)
///
/// #expect(recorder.values == [.initial, .incremented])
/// ```
public actor AsyncStreamRecorder<Element> {
    public private(set) var values: [Element] = []
    private var task: Task<Void, Never>?
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    /// Starts recording emissions from the given async sequence.
    public func record<S: AsyncSequence>(_ sequence: S) where S.Element == Element {
        task = Task {
            do {
                for try await element in sequence {
                    values.append(element)
                    checkWaiters()
                }
            } catch {
                // Stream terminated with error
            }
        }
    }

    /// Waits until at least `count` emissions have been recorded.
    public func waitForEmissions(count: Int, timeout: Duration = .seconds(5)) async throws {
        if values.count >= count {
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.waiters.append((count: count, continuation: continuation))
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }

            try await group.next()
            group.cancelAll()
        }
    }

    /// Cancels recording.
    public func cancel() {
        task?.cancel()
    }

    private func checkWaiters() {
        waiters.removeAll { waiter in
            if values.count >= waiter.count {
                waiter.continuation.resume()
                return true
            }
            return false
        }
    }

    public struct TimeoutError: Error {}
}
```

---

#### InteractorTestHarness

```swift
/// A test harness that simplifies interactor testing with controlled input/output.
///
/// Usage:
/// ```swift
/// @Test func testSearchInteractor() async throws {
///     let harness = InteractorTestHarness(SearchInteractor())
///
///     await harness.send(.updateQuery("swift"))
///     await harness.send(.submit)
///
///     try await harness.assertStates([
///         .initial,
///         .init(query: "swift"),
///         .init(query: "swift", isLoading: true)
///     ])
/// }
/// ```
public actor InteractorTestHarness<I: AsyncInteractor> where I.DomainState: Equatable {
    private let interactor: I
    private let actionContinuation: AsyncStream<I.Action>.Continuation
    private let recorder: AsyncStreamRecorder<I.DomainState>

    public init(_ interactor: I) {
        self.interactor = interactor
        let (actionStream, continuation) = AsyncStream<I.Action>.makeStream()
        self.actionContinuation = continuation
        self.recorder = AsyncStreamRecorder()

        Task {
            await recorder.record(interactor.interact(actionStream))
        }
    }

    /// Sends an action to the interactor.
    public func send(_ action: I.Action) {
        actionContinuation.yield(action)
    }

    /// Finishes the action stream.
    public func finish() {
        actionContinuation.finish()
    }

    /// Returns all recorded states.
    public var states: [I.DomainState] {
        get async { await recorder.values }
    }

    /// Waits for a specific number of state emissions.
    public func waitForStates(count: Int, timeout: Duration = .seconds(5)) async throws {
        try await recorder.waitForEmissions(count: count, timeout: timeout)
    }

    /// Asserts that the recorded states match the expected sequence.
    public func assertStates(
        _ expected: [I.DomainState],
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        try await waitForStates(count: expected.count)
        let actual = await states
        guard actual == expected else {
            throw AssertionError(
                message: "States mismatch.\nExpected: \(expected)\nActual: \(actual)",
                file: file,
                line: line
            )
        }
    }

    public struct AssertionError: Error {
        let message: String
        let file: StaticString
        let line: UInt
    }
}
```

---

#### Test Examples

```swift
import Testing
import AsyncAlgorithms

// MARK: - Basic State Transitions

@Test func testAsyncCounterIncrement() async throws {
    let harness = InteractorTestHarness(CounterInteractor())

    await harness.send(.increment)
    await harness.send(.increment)
    harness.finish()

    try await harness.assertStates([
        .init(count: 0),   // initial
        .init(count: 1),   // after first increment
        .init(count: 2)    // after second increment
    ])
}

// MARK: - Async Effects with .perform

@Test func testAsyncEffect() async throws {
    let mockService = MockDataService()
    mockService.fetchResult = .success(Data())

    let interactor = DataFetchInteractor(service: mockService)
    let harness = InteractorTestHarness(interactor)

    await harness.send(.fetch)
    try await harness.waitForStates(count: 3)  // initial, loading, loaded

    let states = await harness.states
    #expect(states[0] == .idle)
    #expect(states[1] == .loading)
    #expect(states[2] == .loaded(Data()))
}

// MARK: - Observe Pattern Testing

@Test func testObserveEmission() async throws {
    // Create a mock external stream
    let (externalStream, externalContinuation) = AsyncStream<String>.makeStream()

    let interactor = StreamObserverInteractor(externalStream: externalStream)
    let harness = InteractorTestHarness(interactor)

    await harness.send(.startObserving)

    // Simulate external events
    externalContinuation.yield("event1")
    externalContinuation.yield("event2")

    try await harness.waitForStates(count: 4)  // initial, observing, event1, event2

    let states = await harness.states
    #expect(states[2].lastEvent == "event1")
    #expect(states[3].lastEvent == "event2")

    externalContinuation.finish()
}

// MARK: - Debounce with TestClock

@Test func testDebounce() async throws {
    let clock = TestClock()
    let child = SearchQueryInteractor()
    let interactor = Debounce(for: .milliseconds(300), clock: clock) { child }

    let (actionStream, actionContinuation) = AsyncStream<SearchAction>.makeStream()
    let recorder = AsyncStreamRecorder<SearchState>()
    await recorder.record(interactor.interact(actionStream))

    // Rapid actions within debounce window
    actionContinuation.yield(.updateQuery("s"))
    await clock.advance(by: .milliseconds(100))
    actionContinuation.yield(.updateQuery("sw"))
    await clock.advance(by: .milliseconds(100))
    actionContinuation.yield(.updateQuery("swift"))

    // Advance past debounce window
    await clock.advance(by: .milliseconds(400))

    actionContinuation.finish()

    // Only the final value should have been processed
    let states = await recorder.values
    #expect(states.last?.query == "swift")
}

// MARK: - Cancellation Testing

@Test func testCancellation() async throws {
    let interactor = LongRunningInteractor()
    let (actionStream, actionContinuation) = AsyncStream<Action>.makeStream()
    let stateStream = interactor.interact(actionStream)

    let task = Task {
        for await _ in stateStream {
            // Consume states
        }
    }

    actionContinuation.yield(.startLongTask)

    // Cancel before completion
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()

    // Verify task was cancelled (no crash, clean termination)
    await task.value
}
```

---

#### Mock Patterns

```swift
// Service mock with configurable responses
actor MockSearchService: SearchServiceProtocol {
    var searchResults: [SearchResult] = []
    var shouldFail = false
    var callCount = 0

    func search(query: String) async throws -> [SearchResult] {
        callCount += 1
        if shouldFail {
            throw SearchError.networkError
        }
        return searchResults
    }
}

// State fixture builders
extension SearchState {
    static var initial: Self { .init(query: "", results: [], isLoading: false) }

    static func loading(query: String) -> Self {
        .init(query: query, results: [], isLoading: true)
    }

    static func loaded(query: String, results: [SearchResult]) -> Self {
        .init(query: query, results: results, isLoading: false)
    }
}
```

---

### Scalability & Performance

**Expected Load**:
- Interactors handle UI-driven event rates (100s of actions/second max)
- State emissions should complete within 16ms (60fps) for UI updates
- Async work may take seconds (network requests) but shouldn't block state emission

**Performance Considerations**:

1. **AsyncStream vs. Publisher**:
   - AsyncStream has similar overhead to Combine for typical use cases
   - Task creation has ~1-2µs overhead vs. sink subscription
   - For-await-in loops are more efficient than flatMap chains
   - Need benchmarking to validate no regressions

2. **Task Lifecycle**:
   - Each interactor creates 1-2 long-lived tasks
   - Effect tasks are short-lived (per async operation)
   - Task cancellation must be prompt (< 100ms) for responsive UI

3. **Buffering**:
   - `AsyncStream` has default unbounded buffer
   - Use `AsyncChannel` for back-pressure in When interactor
   - State emissions should not accumulate (UI consumes eagerly)

4. **Memory**:
   - No AnyCancellable storage overhead
   - Task references are lightweight
   - State is passed by value (copy-on-write structs)

**Optimization Strategy**:
- Benchmark critical paths (Merge, When, Debounce) vs. Combine equivalents
- Use `withTaskCancellationHandler` for prompt cleanup
- Profile Task creation overhead in hot paths
- Consider `AsyncBufferedByteIterator` for high-throughput streams if needed

---

### Reliability & Security

**Error Handling**:
- AsyncStream uses `Never` failure type (mirroring Combine's `Never`)
- Async work in `.perform` can throw, but errors should be caught and converted to state
- Use Result types in state for error representation

```swift
enum State {
    case loading
    case success(Data)
    case failure(Error)
}

return .perform { currentState, send in
    do {
        let data = try await service.fetch()
        await send(.success(data))
    } catch {
        await send(.failure(error))
    }
}
```

**Cancellation**:
- Task cancellation propagates through for-await-in loops
- Effect tasks must check `Task.isCancelled` for long operations
- `onTermination` handler in AsyncStream ensures cleanup

**Resource Cleanup**:
- Tasks are cancelled on stream termination
- No manual AnyCancellable management needed
- Swift concurrency runtime handles task lifecycle

**Testing for Reliability**:
- Test cancellation behavior explicitly
- Validate no task leaks with Instruments
- Test error paths convert to state correctly

---

### Observability

**Logging Strategy**:
```swift
extension AsyncInteract {
    public func logActions() -> some AsyncInteractor<State, Action> {
        AsyncInteract(initialValue: initialValue) { state, action in
            print("[Interactor] Received action: \(action)")
            let emission = handler(&state, action)
            print("[Interactor] Emitted state: \(state)")
            return emission
        }
    }
}
```

**Monitoring**:
- Use OSLog for structured logging
- Emit signposts for performance profiling
- Track state emission rates in debug builds

**Debugging**:
- AsyncStream enables breakpoints in for-await-in loops
- Stack traces show async call chains (unlike Combine)
- Use `_printChanges()` in SwiftUI for state updates

---

## Operator Mapping: Combine → AsyncSequence

| Combine Operator | swift-async-algorithms Equivalent | Notes |
|------------------|-----------------------------------|-------|
| `.map { }` | `.map { }` (built-in) | AsyncSequence has built-in map |
| `.flatMap { }` | `.flatMap { }` | From swift-async-algorithms (v1.1.1+) |
| `.filter { }` | `.filter { }` (built-in) | AsyncSequence has built-in filter |
| `.merge(with:)` | `merge(_:)` | From swift-async-algorithms |
| `.combineLatest(_:)` | `combineLatest(_:)` | From swift-async-algorithms |
| `.zip(_:)` | `zip(_:)` | From swift-async-algorithms |
| `.debounce(for:scheduler:)` | `.debounce(for:clock:)` | Uses `Clock` protocol instead of Scheduler |
| `.throttle(for:scheduler:)` | `.throttle(for:clock:)` | Uses `Clock` protocol instead of Scheduler |
| `.removeDuplicates()` | `.removeDuplicates()` | From swift-async-algorithms |
| `.append(_:)` | `.chain(_:)` | Concatenates sequences |
| `.compactMap { }` | `.compactMap { }` | Built-in + `.compacted()` in swift-async-algorithms |
| `.eraseToAnyPublisher()` | Not needed | Opaque return types eliminate need |
| `.sink { }` | `for await value in stream` | Terminal iteration |
| `.handleEvents(...)` | Manual side effects in loop | No direct equivalent, use inline side effects |
| `PassthroughSubject` | `AsyncChannel` | Back-pressure aware channel |
| `CurrentValueSubject` | `StateBox` + `AsyncStream` | Custom pattern (see Interact with @MainActor) |

**Available in swift-async-algorithms (not comprehensive)**:
- `merge`, `combineLatest`, `zip` - Combining sequences
- `debounce`, `throttle` - Time-based operations
- `flatMap` - Flattening nested sequences
- `chain`, `joined` - Concatenation
- `chunks`, `chunked` - Grouping
- `adjacentPairs` - Consecutive pairs
- `interspersed` - Insert separators
- `compacted`, `removeDuplicates` - Filtering

**Gaps Requiring Custom Implementation**:
- `handleEvents` for side effects → Inline in for-await-in loop
- `.feedback()` operator → Replaced by `AsyncInteract` primitive

---

## Implementation Roadmap

Since the library is under initial development, we perform a complete migration in one focused effort rather than incremental phases.

### Phase 1: Core Infrastructure

**Goal**: Build the foundational types for AsyncStream-based interactors.

**Tasks**:
- [ ] Add swift-async-algorithms dependency to Package.swift
- [ ] Create `Interactor.swift` protocol (AsyncStream-based, replaces Combine version)
- [ ] Implement `Emission.swift` with `state`, `perform`, `observe` kinds
- [ ] Create `DynamicState.swift` for observe pattern
- [ ] Create `Interact.swift` primitive with feedback loop
- [ ] Implement `InteractorBuilder.swift` result builder

**Files to Create/Replace**:
- `Sources/UnoArchitecture/Domain/Interactor.swift` (replace)
- `Sources/UnoArchitecture/Domain/Emission.swift` (replace)
- `Sources/UnoArchitecture/Domain/DynamicState.swift` (replace)
- `Sources/UnoArchitecture/Domain/Interactor/InteractorBuilder.swift` (replace)
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift` (replace)

**Success Criteria**:
- `Interact` handles `.state`, `.perform`, and `.observe` emissions
- Result builder compiles and composes correctly

---

### Phase 2: Higher-Order Interactors

**Goal**: Implement all composition operators.

**Tasks**:
- [ ] Implement `Merge` interactor
- [ ] Implement `MergeMany` interactor
- [ ] Implement `Debounce` interactor (using swift-async-algorithms)
- [ ] Implement `When` interactor for child embedding
- [ ] Implement `Conditional` interactor (if/else branches)
- [ ] Implement `Empty` interactor
- [ ] Create `Interactors` namespace

**Files to Create/Replace**:
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Merge.swift`
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/MergeMany.swift`
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift`
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Conditional.swift`
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Empty.swift`

**Success Criteria**:
- All higher-order interactors compile and function correctly
- Back-pressure handled in `When` via `AsyncChannel`

---

### Phase 3: Testing Infrastructure

**Goal**: First-class testing support for AsyncStream interactors.

**Tasks**:
- [ ] Create `TestClock` for deterministic time control
- [ ] Create `AsyncStreamRecorder` for emission capture
- [ ] Create `InteractorTestHarness` for ergonomic testing
- [ ] Create state fixture builders and mock patterns
- [ ] Document testing patterns with examples

**Files to Create**:
- `Sources/UnoArchitecture/Testing/TestClock.swift`
- `Sources/UnoArchitecture/Testing/AsyncStreamRecorder.swift`
- `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift`

**Success Criteria**:
- Tests can control time deterministically
- Emission recording is straightforward
- Test harness simplifies common test patterns

---

### Phase 4: Migrate All Interactors

**Goal**: Replace all Combine-based interactors with AsyncStream versions.

**Tasks**:
- [ ] Migrate Counter example interactor
- [ ] Migrate Async Counter example interactor
- [ ] Migrate Search example interactors (SearchInteractor, SearchQueryInteractor)
- [ ] Update all tests to use new testing infrastructure
- [ ] Remove all Combine-specific code from Interactor layer

**Files to Modify**:
- All files in `Examples/*/`
- All test files in `Tests/UnoArchitectureTests/DomainTests/InteractorTests/`

**Success Criteria**:
- All examples work with AsyncStream interactors
- All tests pass
- No Combine imports in Interactor layer

---

### Phase 5: ViewModel Integration

**Goal**: ViewModels consume AsyncStream interactors natively.

**Tasks**:
- [ ] Update `ViewModel` to use Task-based subscriptions
- [ ] Update ViewModel macro for async support
- [ ] Implement proper Task lifecycle (cancellation on deinit)
- [ ] Update all example ViewModels

**Files to Modify**:
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`
- `Sources/UnoArchitectureMacros/Plugins/ViewModelMacro.swift`

**Success Criteria**:
- ViewModels subscribe to AsyncStream state changes
- Task cancellation on ViewModel deallocation
- No memory leaks

---

### Phase 6: Cleanup & Documentation

**Goal**: Remove legacy code and document the new system.

**Tasks**:
- [ ] Remove all Combine-based Interactor code
- [ ] Remove `Combine+FeedbackLoop.swift`
- [ ] Remove `Publishers.Async`
- [ ] Update README with new patterns
- [ ] Create ADR documenting the migration decision

**Files to Delete**:
- `Sources/UnoArchitecture/Internal/Combine/Combine+FeedbackLoop.swift`
- `Sources/UnoArchitecture/Internal/Combine/Publishers+Async.swift`
- Any other Combine-specific interactor utilities

**Success Criteria**:
- No unused Combine code remains
- Documentation reflects current implementation
- ADR captures decision rationale

---

## Migration Strategy

Since we're doing a complete migration (not incremental), the strategy is straightforward:

### Approach

1. **Create new implementations** alongside existing Combine code (temporary)
2. **Validate with tests** that new implementations match existing behavior
3. **Replace old with new** once validated
4. **Delete Combine code** after replacement

### Git Strategy

```
main
  └── feature/async-stream-migration
        ├── Phase 1: Core infrastructure (commits)
        ├── Phase 2: Higher-order interactors (commits)
        ├── Phase 3: Testing infrastructure (commits)
        ├── Phase 4: Migrate examples (commits)
        ├── Phase 5: ViewModel integration (commits)
        └── Phase 6: Cleanup (commits)
```

Single feature branch with logical commits per phase. Merge to main when complete.

### Validation

Before replacing Combine implementations:
1. Write tests for new AsyncStream versions that mirror existing Combine tests
2. Verify behavior matches (same state emissions for same action sequences)
3. Run performance benchmarks to ensure no regressions
4. Manual testing of UI flows

---

## Implementation Guidelines

### File Structure

```
Sources/UnoArchitecture/
  Domain/
    Interactor.swift (existing Combine)
    AsyncInteractor.swift (new)
    Emission.swift (existing)
    AsyncEmission.swift (new)
    Interactor/
      InteractorBuilder.swift (existing)
      AsyncInteractorBuilder.swift (new)
      Interactors/
        Interact.swift (existing)
        AsyncInteract.swift (new)
        Merge.swift (existing)
        AsyncMerge.swift (new)
        ... (parallel hierarchy)
  Extensions/
    Combine+Arch.swift (existing)
    AsyncStream+Arch.swift (new)
    Combine+AsyncStream.swift (adapters)
  Testing/
    TestClock.swift (new)
    AsyncStreamRecorder.swift (new)
```

### Naming Conventions

- Prefix all async types with `Async` (e.g., `AsyncInteractor`, `AsyncMerge`)
- Preserve naming patterns from Combine equivalents
- Use `interact(_:)` method name consistently (not `transform` or `process`)
- Use `body` property for result builder (consistency with SwiftUI)

### Key Patterns to Follow

**1. AsyncStream Creation with Cleanup**:
```swift
AsyncStream { continuation in
    let task = Task {
        // Stream logic
    }

    continuation.onTermination = { @Sendable _ in
        task.cancel()
    }
}
```

**2. For-Await-In with Cancellation**:
```swift
for await value in stream {
    guard !Task.isCancelled else { break }
    // Process value
}
```

**3. Task Lifecycle in Higher-Order Interactors**:
```swift
let tasks: [Task<Void, Never>] = [task1, task2]
defer {
    tasks.forEach { $0.cancel() }
}
```

**4. Using swift-async-algorithms Operators**:
```swift
import AsyncAlgorithms

let merged = merge(stream1, stream2)
let debounced = upstream.debounce(for: .seconds(0.3))
```

### Similar Implementations to Model After

- **SwiftUI's `@State` and `@Binding`**: Progressive disclosure pattern
- **TCA's `Effect` type**: Inspiration for `AsyncEmission`
- **Combine's Publisher protocol**: Mirrored in `AsyncInteractor` structure
- **swift-async-algorithms library**: Use as foundation for operators

**Why no direct codebase equivalents**: This is a new paradigm for the project. The closest analog is the existing Combine-based Interactor system, which we're intentionally replacing.

---

## MainActor Isolation and Send Pattern

This section details the actor isolation strategy, drawing inspiration from TCA's (The Composable Architecture) approach to effect handling.

### Why MainActor Isolation?

All UI state mutations should occur on the main thread. Rather than using actor isolation with explicit hops, we use `@MainActor` directly on the `Interactor` protocol:

1. **Simpler mental model**: All handler code runs on main actor by default
2. **No explicit await**: State access is synchronous within handlers
3. **SwiftUI compatibility**: ViewState updates happen on main thread naturally
4. **Eliminates StateActor**: `StateBox` replaces actor with simpler `@MainActor` class

### The Send Pattern

When effects need to emit state from background work, they use the `Send` callback:

```swift
@MainActor
public struct Send<State: Sendable>: Sendable {
    private let yield: @MainActor (State) -> Void

    public func callAsFunction(_ state: State) {
        guard !Task.isCancelled else { return }
        yield(state)
    }
}
```

**How it works**:
1. The effect closure is NOT `@MainActor` annotated, so it runs on the cooperative thread pool
2. The `Send` struct IS `@MainActor`, so calling `await send(state)` automatically hops to main actor
3. Swift handles the actor hop transparently—no `Task.detached` or `MainActor.run` needed

### Comparison: Task.detached vs Send Pattern

| Aspect | Task.detached | Send Pattern |
|--------|---------------|--------------|
| Background execution | Explicit | Implicit (default for non-isolated async) |
| Main actor hop | `await MainActor.run { }` | `await send(state)` |
| Boilerplate | High | Low |
| Cancellation handling | Manual check | Built into Send |
| Structured concurrency | No (unstructured) | Yes (regular Task) |
| Code at call site | Verbose | Clean |

**Before (Task.detached)**:
```swift
case .perform(let work):
    let task = Task.detached { [stateBox] in
        let newState = await work()
        await MainActor.run {
            stateBox.value = newState
            continuation.yield(newState)
        }
    }
    effectTasks.append(task)
```

**After (Send Pattern)**:
```swift
case .perform(let work):
    let task = Task {
        await work(send)
    }
    effectTasks.append(task)
```

### Usage Examples

**Simple State Transition**:
```swift
case .incrementCount:
    state.count += 1
    return .state
```

**Async API Call**:
```swift
case .fetchUsers:
    state.isLoading = true
    return .perform { currentState, send in
        do {
            let users = try await apiClient.fetchUsers()
            await send(State(users: users, isLoading: false, error: nil))
        } catch {
            await send(State(users: [], isLoading: false, error: error))
        }
    }
```

**Observing a Stream**:
```swift
case .startListening:
    return .observe { currentState, send in
        for await event in websocketStream {
            let current = await currentState.current
            var items = current.items
            items.append(event)
            await send(State(items: items, isConnected: true))
        }
    }
```

### Complete Interactor Example

```swift
@MainActor
struct SearchInteractor: Interactor {
    let apiClient: SearchAPIClient

    var body: some InteractorOf<Self> {
        Interact(initialValue: SearchState()) { state, action in
            switch action {
            case .updateQuery(let query):
                state.query = query
                return .state

            case .search:
                state.isLoading = true
                let query = state.query

                return .perform { currentState, send in
                    do {
                        let results = try await apiClient.search(query)
                        await send(SearchState(
                            query: query,
                            results: results,
                            isLoading: false
                        ))
                    } catch {
                        await send(SearchState(
                            query: query,
                            error: error,
                            isLoading: false
                        ))
                    }
                }

            case .clearResults:
                state.results = []
                return .state
            }
        }
    }
}
```

### Migration Notes

The handler signature remains unchanged: `(inout State, Action) -> Emission<State>`. However, the `Emission` factory methods change:

**Old (returning state directly)**:
```swift
return .perform {
    let data = await api.fetch()
    return State(data: data)
}
```

**New (using DynamicState and Send callback)**:
```swift
return .perform { currentState, send in
    let data = await api.fetch()
    let existing = await currentState.items  // Read fresh state if needed
    await send(State(items: existing + [data]))
}
```

Note: Both `.perform` and `.observe` now have identical signatures `(DynamicState<State>, Send<State>) async -> Void`. The semantic difference is:
- `.perform`: One-shot async work (API call, file I/O, etc.)
- `.observe`: Long-running stream observation (WebSocket, notifications, etc.)

---

## Trade-offs Analysis

### Benefits of Migration

1. **Improved Readability**:
   - Async/await is more intuitive than Combine's operator chains
   - Stack traces show async call paths (vs. opaque Combine internals)
   - No type erasure boilerplate (`eraseToAnyPublisher()` everywhere)

2. **Native Swift Support**:
   - AsyncStream is first-party Swift (Combine is semi-deprecated)
   - Better Swift 6 concurrency integration (Sendable where applicable, actor isolation)
   - Future Swift language features will target async/await

3. **Easier Onboarding**:
   - New developers learn async/await first (industry standard)
   - Combine requires learning separate reactive programming model
   - Testing with AsyncStream is more straightforward

4. **Better Debugging**:
   - Breakpoints work naturally in for-await-in loops
   - Stack traces include async frames
   - Instruments supports Task profiling

5. **Reduced Dependencies**:
   - Combine is a separate framework (though still included in SDK)
   - AsyncStream is part of Swift standard library

### Challenges and Limitations

1. **Migration Effort**:
   - 7-10 weeks for full migration (estimated)
   - Code duplication during transition period
   - Team learning curve for new patterns

2. **Testing Complexity**:
   - Need new testing utilities (TestClock, AsyncStreamRecorder)
   - Async tests are inherently harder to control than Combine's schedulers
   - Race conditions possible if not careful with Task lifecycle

3. **Performance Unknowns**:
   - AsyncStream performance characteristics not as well-studied as Combine
   - Task creation overhead may be higher than sink subscriptions
   - Need benchmarking to validate no regressions

4. **Operator Gaps**:
   - swift-async-algorithms is less mature than Combine
   - Some operators need custom implementation (flatMap with back-pressure)
   - May need to implement missing operators ourselves

5. **Community Resources**:
   - Fewer examples of AsyncStream-based architectures
   - Combine has more Stack Overflow answers and blog posts
   - May need to pioneer patterns ourselves

### Performance Considerations

**Expected Performance Characteristics**:
- **Task creation**: ~1-2µs overhead per Task (acceptable for UI-driven events)
- **AsyncStream iteration**: Comparable to Combine's sink for typical loads
- **Memory**: Task overhead ~hundreds of bytes vs. AnyCancellable ~tens of bytes
- **Cancellation**: Task.cancel() is faster than AnyCancellable.cancel() (no Set iteration)

**Benchmarking Plan**:
1. Benchmark `AsyncInteract` vs. `Interact` for 1000 state transitions
2. Benchmark `AsyncMerge` vs. `Merge` for fan-out scenarios
3. Benchmark `AsyncDebounce` vs. `Debounce` with time-based events
4. Profile memory usage with Instruments (Task graph vs. AnyCancellable storage)

**Acceptable Thresholds**:
- State transitions: < 100µs per transition (10,000 transitions/second)
- Memory: < 10% increase in peak memory usage
- UI responsiveness: No frame drops (< 16ms per state emission)

### Testing Implications

**Pros**:
- Async tests with async/await are more natural than Combine's schedulers
- `TestClock` provides deterministic time control
- No need for RunLoop spinning or expectation waiting

**Cons**:
- Async tests are inherently concurrent (need careful synchronization)
- Task timing is harder to control than scheduler-based time
- Race conditions possible if not using proper synchronization primitives

**Migration Strategy for Tests**:
1. Port synchronous tests first (easiest)
2. Port time-based tests with TestClock
3. Port complex composition tests last (hardest)

**Test Coverage Goal**: 100% test coverage maintained throughout migration.

---

## Detailed Design: Presentation Layer & Macros

This section provides detailed technical design for the ViewModel construct and all Swift Macros that need to be updated as part of the AsyncStream migration. This expands on Phase 5 (ViewModel Integration) with complete implementation guidance.

---

### Current Presentation Layer Architecture

The current architecture uses Combine throughout the presentation layer:

```
┌─────────────────────────────────────────────────────────────────────┐
│                          SwiftUI View                                │
│                  @StateObject var viewModel: MyViewModel             │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ observes viewState
                                 │ calls sendViewEvent()
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     ViewModel (@ViewModel macro)                     │
│                                                                      │
│  Generated by @ViewModel<ViewStateType, ViewEventType>:              │
│  • @Published private(set) var viewState: ViewStateType              │
│  • private let viewEvents = PassthroughSubject<ViewEventType, Never> │
│  • func sendViewEvent(_ event:) { viewEvents.send(event) }           │
│                                                                      │
│  Generated by #subscribe { builder in ... }:                         │
│  • viewEvents                                                        │
│      .interact(with: interactor)         // Combine extension        │
│      .reduce(using: viewStateReducer)    // Combine extension        │
│      .receive(on: scheduler)             // Combine operator         │
│      .assign(to: &$viewState)            // Combine assignment       │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    ViewStateReducer                                  │
│  func reduce(AnyPublisher<DomainState, Never>)                       │
│       -> AnyPublisher<ViewState, Never>                              │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Interactor (Combine-based)                        │
│  func interact(AnyPublisher<Action, Never>)                          │
│       -> AnyPublisher<DomainState, Never>                            │
└─────────────────────────────────────────────────────────────────────┘
```

**Key Combine Dependencies in Presentation Layer**:
1. `PassthroughSubject` - For viewEvents stream
2. `@Published` - For SwiftUI observation
3. `AnyPublisher` - For type-erased streams
4. `AnySchedulerOf<DispatchQueue>` - For scheduler injection (CombineSchedulers)
5. `objectWillChange.sink` - For AnyViewModel forwarding
6. `.receive(on:)`, `.assign(to:)` - Terminal operators

---

### Target Presentation Layer Architecture

After migration, the presentation layer uses AsyncStream with Task-based lifecycle:

```
┌─────────────────────────────────────────────────────────────────────┐
│                          SwiftUI View                                │
│                  @StateObject var viewModel: MyViewModel             │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ observes viewState (still @Published)
                                 │ calls sendViewEvent()
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     ViewModel (@ViewModel macro)                     │
│                                                                      │
│  Generated by @ViewModel<ViewStateType, ViewEventType>:              │
│  • @Published private(set) var viewState: ViewStateType              │
│  • private let (viewEventStream, viewEventContinuation) =            │
│        AsyncStream<ViewEventType>.makeStream()                       │
│  • private var subscriptionTask: Task<Void, Never>?                  │
│  • func sendViewEvent(_ event:) { viewEventContinuation.yield(event)}│
│                                                                      │
│  Generated by #subscribe { builder in ... }:                         │
│  • subscriptionTask = Task { @MainActor in                           │
│      for await domainState in interactor.interact(viewEventStream) { │
│          self.viewState = viewStateReducer.reduce(domainState)       │
│      }                                                               │
│    }                                                                 │
│                                                                      │
│  • deinit { subscriptionTask?.cancel() }                             │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    ViewStateReducer                                  │
│  func reduce(_ domainState: DomainState) -> ViewState                │
│  (Synchronous transformation - no longer needs Publisher)            │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Interactor (AsyncStream-based)                    │
│  func interact(_ upstream: AsyncStream<Action>)                      │
│       -> AsyncStream<DomainState>                                    │
└─────────────────────────────────────────────────────────────────────┘
```

**Key Changes**:
1. `PassthroughSubject` → `AsyncStream.makeStream()` pattern
2. `AnySchedulerOf<DispatchQueue>` → `@MainActor` isolation
3. Combine pipeline → Task-based `for await` loop
4. `.assign(to:)` → Direct property assignment within `@MainActor` Task
5. `AnyCancellable` → `Task` cancellation in deinit

---

### ViewModel Protocol Migration

**Current Implementation** (`Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift`):

```swift
import Combine
import SwiftUI

public protocol ViewModel: ObservableObject {
    associatedtype ViewEventType
    associatedtype ViewStateType

    var viewState: ViewStateType { get }
    func sendViewEvent(_ event: ViewEventType)
}
```

**Target Implementation**:

```swift
import SwiftUI

/// A type that binds a SwiftUI view to your domain/business logic.
///
/// ViewModel coordinates streams of events from UI components and feeds them
/// into the interactor transformation system. State flows uni-directionally
/// from Interactor → ViewStateReducer → ViewModel → View.
///
/// ### Declaring a ViewModel
/// ```swift
/// @ViewModel<CounterViewState, CounterEvent>
/// final class CounterViewModel {
///     init(
///         interactor: AnyInteractor<CounterDomainState, CounterEvent>,
///         viewStateReducer: AnyViewStateReducer<CounterDomainState, CounterViewState>
///     ) {
///         self.viewState = .loading
///         #subscribe { builder in
///             builder
///                 .interactor(interactor)
///                 .viewStateReducer(viewStateReducer)
///         }
///     }
/// }
/// ```
public protocol ViewModel: ObservableObject {
    associatedtype ViewEventType
    associatedtype ViewStateType

    var viewState: ViewStateType { get }
    func sendViewEvent(_ event: ViewEventType)
}

/// A type-erased wrapper around any ``ViewModel``.
@MainActor
public final class AnyViewModel<ViewEvent, ViewState>: ViewModel {
    public var viewState: ViewState {
        viewStateGetter()
    }

    private let viewStateGetter: @MainActor () -> ViewState
    private let viewEventSender: @MainActor (ViewEvent) -> Void
    private var observationTask: Task<Void, Never>?

    /// Creates a type-erased wrapper around `base`.
    ///
    /// The wrapper observes the base ViewModel's objectWillChange to relay
    /// updates to SwiftUI.
    public init<VM: ViewModel>(_ base: VM) where VM.ViewEventType == ViewEvent, VM.ViewStateType == ViewState {
        self.viewEventSender = { [weak base] event in
            base?.sendViewEvent(event)
        }
        self.viewStateGetter = { [weak base] in
            guard let base else {
                fatalError(
                    """
                    Underlying ViewModel with types '\(ViewEvent.self)', '\(ViewState.self)' has been deallocated.
                    """
                )
            }
            return base.viewState
        }

        // Forward objectWillChange using async observation
        self.observationTask = Task { [weak self, weak base] in
            guard let base else { return }
            for await _ in base.objectWillChange.values {
                guard !Task.isCancelled else { break }
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    public func sendViewEvent(_ event: ViewEvent) {
        viewEventSender(event)
    }
}

extension ViewModel {
    /// Erases `self` to ``AnyViewModel``.
    @MainActor
    public func erased() -> AnyViewModel<ViewEventType, ViewStateType> {
        AnyViewModel(self)
    }
}
```

**Key Changes**:
- `AnyCancellable` → `Task<Void, Never>?` with cancellation in deinit
- `objectWillChange.sink` → `objectWillChange.values` (AsyncSequence from Combine)
- Add `@MainActor` annotation for thread safety

---

### ViewStateReducer Migration

**Current Implementation** (`Sources/UnoArchitecture/Presentation/ViewStateReducer/ViewStateReducer.swift`):

Uses `AnyPublisher<DomainState, Never>` → `AnyPublisher<ViewState, Never>`

**Target Implementation**:

ViewStateReducer can be simplified since it's a stateless transformation. Instead of operating on streams, it can simply be a synchronous function:

```swift
/// A type that transforms domain state into view state.
///
/// ``ViewStateReducer`` is a **stateless** transformer. Its purpose is to consume
/// complex `DomainState` and simplify (reduce) it into `ViewState` for UI rendering.
///
/// Feature state accumulation is handled by ``Interactor``. ViewStateReducer only
/// performs the final mapping to view-layer types.
public protocol ViewStateReducer<DomainState, ViewState> {
    associatedtype DomainState
    associatedtype ViewState
    associatedtype Body: ViewStateReducer

    @ViewStateReducerBuilder<DomainState, ViewState>
    var body: Body { get }

    /// Transforms domain state into view state.
    ///
    /// This is the core transformation method. For most implementations,
    /// use `BuildViewState` with a closure.
    func reduce(_ domainState: DomainState) -> ViewState
}

extension ViewStateReducer where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension ViewStateReducer {
    public static func buildViewState(
        reducerBlock: @escaping (DomainState) -> ViewState
    ) -> BuildViewState<DomainState, ViewState> {
        BuildViewState(reducerBlock: reducerBlock)
    }
}

extension ViewStateReducer where Body: ViewStateReducer<DomainState, ViewState> {
    public func reduce(_ domainState: DomainState) -> ViewState {
        self.body.reduce(domainState)
    }
}

public typealias ViewStateReducerOf<V: ViewStateReducer> = ViewStateReducer<V.DomainState, V.ViewState>

/// A type-erased wrapper around any ``ViewStateReducer``.
public struct AnyViewStateReducer<DomainState, ViewState>: ViewStateReducer {
    private let reduceFunc: (DomainState) -> ViewState

    public init<VS: ViewStateReducer>(_ base: VS)
    where VS.DomainState == DomainState, VS.ViewState == ViewState {
        self.reduceFunc = base.reduce(_:)
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(_ domainState: DomainState) -> ViewState {
        reduceFunc(domainState)
    }
}

extension ViewStateReducer {
    /// Returns a type-erased wrapper of `self`.
    public func eraseToAnyReducer() -> AnyViewStateReducer<DomainState, ViewState> {
        AnyViewStateReducer(self)
    }
}
```

**Key Changes**:
- `reduce(AnyPublisher<DomainState, Never>)` → `reduce(DomainState)` (synchronous)
- No longer wraps streams, just transforms individual values
- ViewModel calls `viewStateReducer.reduce(domainState)` in the async loop

**Rationale**: ViewStateReducer is stateless by design. It doesn't need to operate on streams—it just maps domain state to view state. The stream iteration happens in the ViewModel's subscription Task.

---

### BuildViewState Migration

**Target Implementation** (`Sources/UnoArchitecture/Presentation/ViewStateReducer/BuildViewState.swift`):

```swift
/// The core building block for view state reducers.
///
/// `BuildViewState` wraps a transformation closure that converts domain state to view state.
public struct BuildViewState<DomainState, ViewState>: ViewStateReducer {
    private let reducerBlock: (DomainState) -> ViewState

    public init(reducerBlock: @escaping (DomainState) -> ViewState) {
        self.reducerBlock = reducerBlock
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(_ domainState: DomainState) -> ViewState {
        reducerBlock(domainState)
    }
}
```

---

### Macro Updates

#### @ViewModel Macro Migration

**Current Generated Code** (`ViewModelMacro.swift`):

```swift
@Published private(set) var viewState: ViewStateType
private let viewEvents = PassthroughSubject<ViewEventType, Never>()
func sendViewEvent(_ event: ViewEventType) {
    viewEvents.send(event)
}
```

**Target Generated Code**:

```swift
@Published private(set) var viewState: ViewStateType
private let viewEventContinuation: AsyncStream<ViewEventType>.Continuation
private let viewEventStream: AsyncStream<ViewEventType>
private var subscriptionTask: Task<Void, Never>?

func sendViewEvent(_ event: ViewEventType) {
    viewEventContinuation.yield(event)
}

deinit {
    viewEventContinuation.finish()
    subscriptionTask?.cancel()
}
```

**Implementation** (`Sources/UnoArchitectureMacros/Plugins/ViewModelMacro.swift`):

```swift
extension ViewModelMacro: MemberMacro {
    public static func expansion<D: DeclGroupSyntax, C: MacroExpansionContext>(
        of node: AttributeSyntax,
        providingMembersOf declaration: D,
        in context: C
    ) throws -> [DeclSyntax] {
        guard let attrName = node.attributeName.as(IdentifierTypeSyntax.self),
              let generics = attrName.genericArgumentClause,
              generics.arguments.count == 2
        else {
            context.diagnose(
                Diagnostic(
                    node: node.attributeName,
                    message: MacroExpansionErrorMessage(
                        "@ViewModel macro requires exactly 2 generic arguments: ViewStateType and ViewEventType"
                    )
                )
            )
            return []
        }

        let argumentsArray = generics
            .arguments
            .compactMap { $0.argument.as(IdentifierTypeSyntax.self) }

        guard argumentsArray.count == 2 else {
            context.diagnose(
                Diagnostic(
                    node: node.attributeName,
                    message: MacroExpansionErrorMessage(
                        "Could not parse generic arguments for @ViewModel macro"
                    )
                )
            )
            return []
        }

        let viewStateType = argumentsArray[0].name.text
        let viewEventType = argumentsArray[1].name.text

        let memberBlock = declaration.memberBlock
        let existingMembers = memberBlock.members.compactMap { member in
            if let varDecl = member.decl.as(VariableDeclSyntax.self),
               let binding = varDecl.bindings.first,
               let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                return pattern.identifier.text
            }
            if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
                return funcDecl.name.text
            }
            return nil
        }

        var declarations: [DeclSyntax] = []

        // Generate @Published viewState property
        if !existingMembers.contains("viewState") {
            declarations.append(
                """
                @Published private(set) var viewState: \(raw: viewStateType)
                """
            )
        }

        // Generate AsyncStream-based view events
        if !existingMembers.contains("viewEventStream") {
            declarations.append(
                """
                private let viewEventStream: AsyncStream<\(raw: viewEventType)>
                """
            )
        }

        if !existingMembers.contains("viewEventContinuation") {
            declarations.append(
                """
                private let viewEventContinuation: AsyncStream<\(raw: viewEventType)>.Continuation
                """
            )
        }

        // Generate subscription task storage
        if !existingMembers.contains("subscriptionTask") {
            declarations.append(
                """
                private var subscriptionTask: Task<Void, Never>?
                """
            )
        }

        // Generate sendViewEvent method
        if !existingMembers.contains("sendViewEvent") {
            declarations.append(
                """
                func sendViewEvent(_ event: \(raw: viewEventType)) {
                    viewEventContinuation.yield(event)
                }
                """
            )
        }

        // Generate deinit for cleanup
        declarations.append(
            """
            deinit {
                viewEventContinuation.finish()
                subscriptionTask?.cancel()
            }
            """
        )

        return declarations
    }
}
```

**Note**: The macro now generates the stream/continuation pair as separate properties. The initializer must call `AsyncStream<ViewEventType>.makeStream()` and assign both. This is handled by requiring users to initialize these in their init or by generating an initializer helper.

---

#### #subscribe Macro Migration

**Current Generated Code**:

```swift
viewEvents
    .interact(with: interactor)
    .reduce(using: viewStateReducer)
    .receive(on: scheduler)
    .assign(to: &$viewState)
```

**Target Generated Code**:

```swift
(viewEventStream, viewEventContinuation) = AsyncStream<ViewEventType>.makeStream()
subscriptionTask = Task { @MainActor [weak self] in
    guard let self else { return }
    for await domainState in interactor.interact(self.viewEventStream) {
        guard !Task.isCancelled else { break }
        self.viewState = viewStateReducer.reduce(domainState)
    }
}
```

**Implementation** (`Sources/UnoArchitectureMacros/Plugins/SubscribeMacro.swift`):

```swift
extension SubscribeMacro: ExpressionMacro {
    public static func expansion<Node: FreestandingMacroExpansionSyntax, Context: MacroExpansionContext>(
        of node: Node,
        in context: Context
    ) throws -> ExprSyntax {
        guard node.trailingClosure != nil else {
            context.diagnose(SubscribeMacroDiagnostics.missingTrailingClosure(node: node))
            return ExprSyntax("()")
        }

        let closure = node.trailingClosure!

        var extractedBuilderName: String?
        if let signature = closure.signature {
            for token in signature.tokens(viewMode: .sourceAccurate) {
                if case .identifier(let name) = token.tokenKind {
                    extractedBuilderName = name
                    break
                }
            }
        }

        guard let builderName = extractedBuilderName else {
            context.diagnose(SubscribeMacroDiagnostics.missingBuilderParameter(node: closure))
            return ExprSyntax("()")
        }

        let collector = BuilderCallCollector(builderName: builderName)
        collector.walk(Syntax(closure))
        let configuration = collector.configuration

        guard let interactorExpr = configuration.interactor else {
            context.diagnose(SubscribeMacroDiagnostics.missingInteractor(node: Syntax(closure)))
            return ExprSyntax("()")
        }

        let pipeline: String
        if let reducerExpr = configuration.viewStateReducer?.trimmedDescription {
            pipeline = """
                do {
                    let (stream, continuation) = AsyncStream.makeStream(of: type(of: self).ViewEventType.self)
                    self.viewEventStream = stream
                    self.viewEventContinuation = continuation
                    self.subscriptionTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        for await domainState in \(interactorExpr.trimmedDescription).interact(self.viewEventStream) {
                            guard !Task.isCancelled else { break }
                            self.viewState = \(reducerExpr).reduce(domainState)
                        }
                    }
                }
                """
        } else {
            // No reducer - domain state is view state
            pipeline = """
                do {
                    let (stream, continuation) = AsyncStream.makeStream(of: type(of: self).ViewEventType.self)
                    self.viewEventStream = stream
                    self.viewEventContinuation = continuation
                    self.subscriptionTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        for await domainState in \(interactorExpr.trimmedDescription).interact(self.viewEventStream) {
                            guard !Task.isCancelled else { break }
                            self.viewState = domainState
                        }
                    }
                }
                """
        }

        return ExprSyntax(stringLiteral: pipeline)
    }
}
```

**Key Changes**:
- Creates `AsyncStream.makeStream()` for event channel
- Uses `Task { @MainActor [weak self] in ... }` for subscription lifecycle
- `for await` loop replaces Combine pipeline
- Direct property assignment instead of `.assign(to:)`
- Cancellation check in loop for proper cleanup

---

#### @Interactor Macro (Minimal Changes)

The `@Interactor` macro primarily generates typealiases and applies `@InteractorBuilder`. Since the `Interactor` protocol signature changes but typealiases remain the same, minimal changes are needed:

**Changes Required**:
- Update `InteractorBuilder` attribute generation if builder signature changes
- No changes to typealias generation

---

#### @ViewStateReducer Macro (Minimal Changes)

Similar to `@Interactor`, the `@ViewStateReducer` macro generates typealiases. Since `ViewStateReducer` simplifies to synchronous transformation, the macro needs minimal updates:

**Changes Required**:
- Update builder attribute if `ViewStateReducerBuilder` changes
- No changes to typealias generation

---

### ViewModelBuilder Migration

**Current Implementation** uses `AnySchedulerOf<DispatchQueue>` from CombineSchedulers.

**Target Implementation**:

```swift
import Foundation

/// A builder that assembles the moving parts required to construct a ``ViewModel``.
///
/// Used internally by the ``@ViewModel`` macro's `#subscribe` expansion.
public final class ViewModelBuilder<DomainEvent, DomainState, ViewState>: @unchecked Sendable {
    private var _interactor: AnyInteractor<DomainState, DomainEvent>?
    private var _viewStateReducer: AnyViewStateReducer<DomainState, ViewState>?

    public init() {}

    @discardableResult
    public func interactor(_ interactor: AnyInteractor<DomainState, DomainEvent>) -> Self {
        self._interactor = interactor
        return self
    }

    @discardableResult
    public func viewStateReducer(
        _ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    ) -> Self {
        self._viewStateReducer = viewStateReducer
        return self
    }

    func build() throws -> ViewModelConfiguration<DomainEvent, DomainState, ViewState> {
        guard let _interactor else {
            throw ViewModelBuilderError.missingInteractor
        }

        return ViewModelConfiguration(
            interactor: _interactor,
            viewStateReducer: _viewStateReducer
        )
    }
}

/// The concrete configuration produced by ``ViewModelBuilder/build()``.
public struct ViewModelConfiguration<DomainEvent, DomainState, ViewState> {
    let interactor: AnyInteractor<DomainState, DomainEvent>
    let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>?
}

public enum ViewModelBuilderError: Error {
    case missingInteractor
}
```

**Key Changes**:
- Removed `_viewEventsReceiver` and `_viewStateReceiver` scheduler properties
- Removed CombineSchedulers dependency
- Simplified to just interactor and viewStateReducer configuration

---

### AsyncStream Extensions

**New File**: `Sources/UnoArchitecture/Extensions/AsyncStream+Arch.swift`

```swift
/// Convenience extension for interactor integration with AsyncStream.
extension AsyncStream {
    /// Feeds this stream through an interactor and returns the resulting state stream.
    public func interact<I: Interactor>(
        with interactor: I
    ) -> AsyncStream<I.DomainState> where Element == I.Action {
        interactor.interact(self)
    }
}
```

---

### Example Migration: SearchViewModel

**Current Implementation**:

```swift
@ViewModel<SearchViewState, SearchEvent>
final class SearchViewModel {
    init(
        scheduler: AnySchedulerOf<DispatchQueue> = .main,
        interactor: AnyInteractor<SearchDomainState, SearchEvent>,
        viewStateReducer: AnyViewStateReducer<SearchDomainState, SearchViewState>
    ) {
        self.viewState = .none
        #subscribe { builder in
            builder
                .interactor(interactor)
                .viewStateReducer(viewStateReducer)
                .viewStateReceiver(scheduler)
        }
    }
}
```

**Target Implementation**:

```swift
@ViewModel<SearchViewState, SearchEvent>
final class SearchViewModel {
    init(
        interactor: AnyInteractor<SearchDomainState, SearchEvent>,
        viewStateReducer: AnyViewStateReducer<SearchDomainState, SearchViewState>
    ) {
        self.viewState = .none
        #subscribe { builder in
            builder
                .interactor(interactor)
                .viewStateReducer(viewStateReducer)
        }
    }
}
```

**Key Changes**:
- Removed `scheduler` parameter (MainActor handles thread safety)
- Removed `.viewStateReceiver(scheduler)` call

---

### Files to Modify/Create

**Presentation Layer**:
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift` - Update protocol and AnyViewModel
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModelBuilder.swift` - Remove scheduler, simplify
- `Sources/UnoArchitecture/Presentation/ViewStateReducer/ViewStateReducer.swift` - Change to sync reduce
- `Sources/UnoArchitecture/Presentation/ViewStateReducer/BuildViewState.swift` - Update to sync
- `Sources/UnoArchitecture/Presentation/ViewStateReducer/ViewStateReducerBuilder.swift` - Update for sync API

**Macros**:
- `Sources/UnoArchitectureMacros/Plugins/ViewModelMacro.swift` - AsyncStream generation
- `Sources/UnoArchitectureMacros/Plugins/SubscribeMacro.swift` - Task-based pipeline

**Extensions**:
- `Sources/UnoArchitecture/Extensions/AsyncStream+Arch.swift` - New file
- `Sources/UnoArchitecture/Extensions/Combine+Arch.swift` - Delete after migration

**Public API**:
- `Sources/UnoArchitecture/Macros.swift` - Update #subscribe signature if needed

**Tests**:
- `Tests/UnoArchitectureMacrosTests/ViewModelMacroTests.swift` - Update expected expansion
- `Tests/UnoArchitectureMacrosTests/SubscribeMacroTests.swift` - Update expected expansion (if exists)
- `Tests/UnoArchitectureTests/PresentationTests/ViewModelTests.swift` - Update for async
- `Tests/UnoArchitectureTests/PresentationTests/ViewStateReducerTests.swift` - Update for sync API
- All mock files in `Tests/UnoArchitectureTests/PresentationTests/Mocks/`

**Examples**:
- `Examples/Search/Search/Architecture/SearchViewModel.swift` - Remove scheduler
- `Examples/Search/Search/Architecture/SearchViewStateReducer.swift` - Update to sync

**Dependencies**:
- `Package.swift` - Remove CombineSchedulers dependency (after full migration)

---

### Implementation Order for Phase 5

Since Phase 5 has many interconnected parts, here's the recommended implementation order:

**Phase 5a: Core Protocol Updates**
1. Update `ViewStateReducer` to synchronous `reduce(DomainState) -> ViewState`
2. Update `BuildViewState` for synchronous API
3. Update `ViewStateReducerBuilder` for new API
4. Update `AnyViewStateReducer` for synchronous wrapping

**Phase 5b: ViewModel Infrastructure**
1. Update `ViewModelBuilder` (remove schedulers)
2. Update `ViewModel` protocol (minimal - keep ObservableObject)
3. Update `AnyViewModel` (Task-based observation)

**Phase 5c: Macro Updates**
1. Update `ViewModelMacro` (AsyncStream members, deinit)
2. Update `SubscribeMacro` (Task-based pipeline)
3. Test macro expansions manually

**Phase 5d: Extension Updates**
1. Create `AsyncStream+Arch.swift`
2. Keep `Combine+Arch.swift` temporarily for incremental testing

**Phase 5e: Example & Test Updates**
1. Update `SearchViewModel` and related types
2. Update all ViewModel tests
3. Update all ViewStateReducer tests
4. Update macro expansion tests

**Phase 5f: Cleanup**
1. Remove `Combine+Arch.swift`
2. Remove CombineSchedulers from `ViewModelBuilder`
3. Update Package.swift dependencies

---

### Testing Strategy for Presentation Layer

**ViewModel Testing**:

```swift
@Test func testViewModelEmitsStateOnEvent() async throws {
    let interactor = MockInteractor<DomainState, Event>()
    let reducer = MockReducer<DomainState, ViewState>()

    let viewModel = TestViewModel(
        interactor: interactor.eraseToAnyInteractor(),
        viewStateReducer: reducer.eraseToAnyReducer()
    )

    // Send event
    viewModel.sendViewEvent(.someEvent)

    // Wait for state update
    try await Task.sleep(for: .milliseconds(10))

    #expect(viewModel.viewState == expectedViewState)
}

@Test func testViewModelCancelsOnDeinit() async throws {
    var viewModel: TestViewModel? = TestViewModel(...)
    let taskWasCancelled = expectation(description: "Task cancelled")

    // Get reference to internal task
    let task = viewModel?.subscriptionTask

    // Deallocate
    viewModel = nil

    // Verify cancellation
    #expect(task?.isCancelled == true)
}
```

**ViewStateReducer Testing** (simplified since synchronous):

```swift
@Test func testReducerTransformsDomainState() {
    let reducer = SearchViewStateReducer()

    let domainState = SearchDomainState(query: "test", results: [.mock])
    let viewState = reducer.reduce(domainState)

    #expect(viewState.displayedQuery == "test")
    #expect(viewState.resultCount == 1)
}
```

---

## Open Questions

1. **Should we use `some AsyncSequence` or `AsyncStream` in signatures?**
   - `some AsyncSequence`: More flexible, harder to debug
   - `AsyncStream`: More concrete, easier to understand
   - **Recommendation**: Start with `AsyncStream`, evaluate `some AsyncSequence` later

2. **How do we handle SharedState patterns (e.g., CurrentValueSubject equivalent)?**
   - AsyncStream doesn't have a "current value" concept
   - Options: Create `StateStream` wrapper, use `AsyncChannel`, or rethink pattern
   - **Recommendation**: Investigate in Phase 1, document findings

3. **What's the migration path for ViewStateReducer?**
   - ViewStateReducer uses Combine's map operator
   - Should we create `AsyncViewStateReducer` or make it work with both?
   - **Recommendation**: Address in Phase 5 (ViewModel integration)

4. **Do we need back-pressure in all cases?**
   - Combine's `flatMap(maxPublishers: .max(1))` provides back-pressure
   - AsyncChannel provides back-pressure for AsyncStream
   - **Recommendation**: Use `AsyncChannel` in `When` interactor, evaluate elsewhere

5. **How do we handle hot vs. cold streams?**
   - Combine has clear hot/cold semantics (PassthroughSubject vs. Just)
   - AsyncStream is always "hot" (starts on creation)
   - **Recommendation**: Document semantic differences, create wrappers if needed

6. **Should we maintain CombineSchedulers dependency?**
   - CombineSchedulers provides TestScheduler for controlled time
   - Swift concurrency uses `Clock` protocol
   - **Recommendation**: Deprecate CombineSchedulers, use TestClock for new tests

---

## References

### Documentation
- [Swift AsyncSequence](https://developer.apple.com/documentation/swift/asyncsequence)
- [Swift AsyncStream](https://developer.apple.com/documentation/swift/asyncstream)
- [swift-async-algorithms](https://github.com/apple/swift-async-algorithms)
- [Combine Framework](https://developer.apple.com/documentation/combine)

### Articles
- [Matt Neuburg on flatMap](https://www.apeth.com/UnderstandingCombine/operators/operatorsTransformersBlockers/operatorsflatmap.html)
- [Martin Fowler - Strangler Fig Pattern](https://martinfowler.com/bliki/StranglerFigApplication.html)

### Related Work
- TCA's Effect type (Point-Free)
- ReactiveSwift's Signal/SignalProducer patterns
- RxSwift migration guides to Combine

### Internal Context
- `thoughts/shared/plans/async-stream-migration/main-actor-send-pattern.md` - Detailed design for MainActor isolation and Send callback pattern
- `thoughts/shared/plans/2025-12-28_debounce-interactor-and-search-example.md`
- `thoughts/shared/plans/2025-12-28_fix-when-interactor-types.md`
- Existing Interactor test suite in `Tests/UnoArchitectureTests/DomainTests/InteractorTests/`
