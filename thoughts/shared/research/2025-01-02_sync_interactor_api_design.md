# Synchronous Interactor API Design

Last Updated: 2025-01-02

## Executive Summary

This design proposes transforming the Uno Architecture's core Interactor protocol from asynchronous stream-based (`AsyncStream<Action> -> AsyncStream<State>`) to synchronous function-based (`(inout State, Action) -> Emission<State>`). This change enables ViewModel to immediately capture effect tasks when processing actions, making `sendViewEvent` naturally returnable as `EventTask` without correlation infrastructure. The synchronous API simplifies the mental model, improves testability, and aligns with reducer patterns familiar from TCA while preserving Uno's unique Emission-based effect system.

**Key Design Decision - Initial State**: The protocol now requires `var initialValue: DomainState { get }` with default implementations that delegate to `body.initialValue`. This enables ViewModel to initialize domain state eagerly from `interactor.initialValue`, eliminating the need for DomainBox and its `.waiting` state. Consumers provide initial ViewState separately, and ViewModel trusts this value without calling the reducer on initialization. This approach is type-safe, composable (higher-order interactors compute initial state from children), and eliminates an entire class of runtime errors.

## Context & Requirements

### Problem Statement

The current async stream-based Interactor protocol creates an asynchronous gap between sending an action and obtaining effect tasks:

```swift
// Current: Actions go into a stream, effects spawn asynchronously
func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState>

// ViewModel sends action...
viewEventContinuation?.yield(event)  // Action enters stream
// ...but by the time handler runs and spawns effects, sendViewEvent has returned
```

This gap necessitates complex correlation infrastructure (ActionContext, task-locals, 10ms delays) to bridge the action to its effects, as documented in the EventTask design.

### Why Synchronous is Better

A synchronous API eliminates this gap entirely:

```swift
// Proposed: Synchronous call returns emission with tasks immediately
func interact(state: inout DomainState, action: Action) -> Emission<DomainState>

// ViewModel can immediately extract tasks
let emission = interactor.interact(state: &state, action: action)
let tasks = emission.effectTasks  // Available synchronously!
return EventTask(id: eventID, tasks: tasks)
```

This makes the EventTask system trivial - no correlation IDs, no task-locals, no timing delays.

### Note on Breaking Changes

This library is in alpha development, so breaking changes are acceptable. We will not maintain backward compatibility with the async stream API.

### Requirements

1. **Synchronous Core**: `interact` becomes a pure function: `(inout State, Action) -> Emission<State>`
2. **Reuse Emission**: Keep existing `Emission` type with `.state`, `.perform`, `.observe`
3. **Immediate Task Capture**: ViewModel can extract effect tasks synchronously from the returned Emission
4. **Composition Works**: Higher-order interactors (Merge, When, MergeMany) compose emissions from children
5. **StateBox Elimination**: With `inout State`, no need for StateBox - state management becomes explicit
6. **Thread Safety**: ViewModel remains `@MainActor`; Interactor protocol itself does NOT require `@MainActor` (handlers are `@MainActor` but protocol is agnostic)
7. **Initial State Protocol**: Interactor protocol requires `var initialValue: DomainState { get }` so ViewModel can initialize eagerly (no DomainBox/waiting state needed)
8. **Simple Cancellation**: `EventTask.cancel()` for per-event cancellation; ViewModel cancels all effects on deinit

### Benefits

1. **Simpler Mental Model**: Reducer-like synchronous function is easier to reason about
2. **Natural EventTask**: No correlation infrastructure needed - tasks are immediately available
3. **Better Testability**: Synchronous processing makes deterministic testing trivial
4. **Clearer State Ownership**: `inout State` makes state mutations explicit
5. **Performance**: Eliminates AsyncStream overhead for action processing
6. **Alignment with Industry**: Similar to TCA's reducer model, familiar to many developers

## Existing Codebase Analysis

### Current Async Stream Pattern

**Interact.swift (lines 92-145)**:
- Uses `AsyncStream` with continuation for state emissions
- Maintains local `StateBox` for mutable state
- Spawns effect tasks and tracks them in local array
- Effect tasks cancelled when stream finishes

**Key Issue**: By the time `handler(&state, action)` executes and returns an `Emission`, the `sendViewEvent` call in ViewModel has already returned. The effect tasks are created inside the stream's Task, isolated from the caller.

### Current Higher-Order Interactors

**Merge.swift**: Creates new child streams for each action, iterates emissions sequentially
**When.swift**: Routes actions via AsyncChannel, child emissions converted to parent actions
**MergeMany.swift**: Similar to Merge, iterates all children sequentially

**Key Issue**: Each higher-order interactor creates new streams, adding layers of indirection. Composition happens via stream merging, not emission merging.

### Current Emission Type

```swift
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        case state
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)
    }

    let kind: Kind
}
```

**Key Observation**: Emission already describes "what to do" with state. It just needs to be extended to carry the actual spawned tasks for composition.

### Pattern Evaluation: Async Streams Are Wrong Abstraction

**Red Flags**:
1. **Async where sync suffices**: Action processing is inherently synchronous (mutation + effect decision). Wrapping in AsyncStream adds unnecessary complexity.
2. **Loss of immediate feedback**: Cannot return anything from `sendViewEvent` because action processing happens later
3. **Difficult composition**: Higher-order interactors must create new streams and merge them, adding layers
4. **Hidden state management**: StateBox required because state lives inside stream closure
5. **Testing complexity**: Must await arbitrary delays for effects to spawn

**Why This Happened**: The async stream design optimized for long-running observations (`.observe`) at the expense of the common case (synchronous state mutation + async effects). But `.observe` effects can still be async while the core processing is sync.

**Better Pattern**: Synchronous reducers that return effect descriptions (Emission). This is a proven pattern (TCA, Elm, Redux-Saga) that separates "deciding what to do" (sync) from "doing it" (async).

## Architectural Approaches

### Approach 1: Pure Sync Reducer (Recommended)

**Overview**: Transform Interactor to synchronous function returning Emission, spawn tasks in ViewModel.

**Architecture**:
```
Action → Interactor.interact(state: &state, action) [SYNC] → Emission →
ViewModel spawns tasks from emission → EventTask wraps tasks
```

**Key Components**:

1. **New Interactor Protocol**:
```swift
public protocol Interactor<DomainState, Action> {
    associatedtype DomainState: Sendable
    associatedtype Action: Sendable
    associatedtype Body: Interactor

    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    // NEW: Synchronous processing
    func interact(state: inout DomainState, action: Action) -> Emission<DomainState>
}
```

2. **Enhanced Emission** with task carrier:
```swift
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        case state
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case merge([Emission<State>])  // NEW: For composition
    }

    let kind: Kind

    // Convenience for composing emissions
    public static func merge(_ emissions: [Emission<State>]) -> Emission<State> {
        Emission(kind: .merge(emissions))
    }
}
```

3. **Simplified Interact**:
```swift
public struct Interact<State: Sendable, Action: Sendable>: Interactor {
    public typealias Handler = @MainActor (inout State, Action) -> Emission<State>

    private let handler: Handler

    public func interact(state: inout State, action: Action) -> Emission<State> {
        handler(&state, action)  // Just call the handler!
    }
}
```

4. **ViewModel Task Spawning**:
```swift
@MainActor
public final class ViewModel<Action, DomainState, ViewState> {
    private var domainState: DomainState
    private var effectTasks: [Task<Void, Never>] = []

    public func sendViewEvent(_ event: Action) -> EventTask {
        // Synchronously process action
        let emission = interactor.interact(state: &domainState, action: event)

        // Update view state
        viewStateReducer.reduce(domainState, into: &viewState)

        // Spawn effect tasks from emission
        let tasks = spawnTasks(from: emission)

        return EventTask(rawValue: Task {
            await withTaskGroup(of: Void.self) { group in
                for task in tasks {
                    group.addTask { await task.value }
                }
            }
        })
    }

    private func spawnTasks(from emission: Emission<DomainState>) -> [Task<Void, Never>] {
        switch emission.kind {
        case .state:
            return []

        case .perform(let work):
            let dynamicState = DynamicState { [weak self] in
                await self?.domainState ?? domainState
            }
            let task = Task {
                await work(dynamicState, Send { [weak self] newState in
                    guard let self else { return }
                    self.domainState = newState
                    self.viewStateReducer.reduce(newState, into: &self.viewState)
                })
            }
            effectTasks.append(task)
            return [task]

        case .observe(let stream):
            // Similar to .perform
            let task = Task { await stream(dynamicState, send) }
            effectTasks.append(task)
            return [task]

        case .merge(let emissions):
            return emissions.flatMap { spawnTasks(from: $0) }
        }
    }
}
```

**Pros**:
- **Immediate task capture**: No correlation infrastructure needed
- **Simple mental model**: Reducer pattern, widely understood
- **Explicit state**: `inout State` makes mutations clear
- **Natural composition**: Emissions compose via `.merge`
- **Better performance**: No AsyncStream overhead
- **Deterministic testing**: Synchronous processing is predictable

**Cons**:
- **Breaking change**: Incompatible with existing Interactor implementations
- **Migration required**: All interactors must be rewritten
- **Loss of stream backpressure**: No natural backpressure mechanism (though actions are typically UI-driven)

**Trade-offs**:
- **Pro**: Eliminates entire classes of complexity (correlation, task-locals, timing)
- **Pro**: Aligns with proven reducer patterns (TCA, Elm)
- **Con**: Requires framework-wide migration
- **Risk**: Long-running observations need careful handling in ViewModel

---

### Approach 2: Hybrid Sync/Async Bridge (NOT RECOMMENDED)

**Overview**: Keep async stream API for backward compatibility, add sync API alongside.

**Why Not**: Since the library is in alpha, maintaining backward compatibility adds unnecessary complexity. The hybrid approach requires:
- Two code paths in ViewModel
- Bridging between sync and async (non-trivial)
- Higher-order interactors supporting both child types
- Confusing developer experience

**Verdict**: Skip this approach. Direct replacement is cleaner for an alpha library.

---

### Approach 3: Async/Await without Streams

**Overview**: Keep async processing but replace AsyncStream with direct async function calls.

**Architecture**:
```
Action → async interact(state:action:) → (State, [Task]) returned
ViewModel awaits result → EventTask wraps tasks
```

**Key Components**:

1. **Async Function Interactor**:
```swift
public protocol Interactor<DomainState, Action> {
    // Returns new state and spawned tasks
    func interact(
        state: DomainState,
        action: Action
    ) async -> (DomainState, [Task<Void, Never>])
}
```

2. **Handler Pattern**:
```swift
public struct Interact<State: Sendable, Action: Sendable>: Interactor {
    public typealias Handler = @MainActor (State, Action) async -> (State, [Task<Void, Never>])

    private let handler: Handler

    public func interact(state: State, action: Action) async -> (State, [Task<Void, Never>]) {
        await handler(state, action)
    }
}
```

3. **ViewModel**:
```swift
public func sendViewEvent(_ event: Action) -> EventTask {
    let eventTask = Task { @MainActor in
        let (newState, tasks) = await interactor.interact(state: domainState, action: event)
        domainState = newState
        viewStateReducer.reduce(newState, into: &viewState)

        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask { await task.value }
            }
        }
    }
    return EventTask(rawValue: eventTask)
}
```

**Pros**:
- **Simple API**: Direct function call, no streams
- **Immediate task capture**: Tasks returned in tuple
- **Async-friendly**: Natural for async operations

**Cons**:
- **Misleading**: Action processing is synchronous, but API is async
- **Performance**: Unnecessary async overhead for sync operations
- **State copying**: State passed by value, must return new copy
- **Testing**: Async testing still more complex than sync
- **Unclear semantics**: When does handler need to be async vs sync?

**Trade-offs**:
- **Pro**: Simpler than stream-based approach
- **Con**: Async where sync is more appropriate
- **Risk**: Encourages anti-patterns (awaiting in reducers)

---

## Recommended Approach: Pure Sync Reducer (Approach 1)

Approach 1 is the clear winner for Uno Architecture because:

### Why This Approach

1. **Right Abstraction**: Action processing is fundamentally synchronous (mutate state + decide effects). The async part is effect execution, not effect decision-making.

2. **Eliminates Accidental Complexity**: The EventTask correlation infrastructure (ActionContext, task-locals, 10ms delays) becomes unnecessary. ViewModel synchronously gets Emission, spawns tasks, done.

3. **Proven Pattern**: TCA's reducer (`(inout State, Action) -> Effect`), Elm's update function, Redux's reducers - all synchronous. This is a well-understood pattern.

4. **Better Composition**: Emissions naturally compose via `.merge`, no need for stream gymnastics.

5. **Clearer Semantics**:
   - Handler decides: "Given this state and action, emit this state and perform these effects"
   - ViewModel executes: "Apply state change, spawn effect tasks, return EventTask"
   - Clear separation of concerns

6. **Testability**: Synchronous handlers are trivially testable - pass state and action, assert returned emission. No awaiting, no timing issues.

### Why Not Other Approaches

**Approach 2 (Hybrid)**:
- Maintaining two APIs is a maintenance nightmare
- Bridging between sync and async is non-trivial (where does initial state come from?)
- Confusing for developers - which API should they use?
- Doesn't solve the fundamental problem, just offers a migration path

**Approach 3 (Async Function)**:
- Async is the wrong abstraction for synchronous work
- Still requires awaiting in ViewModel, adds latency
- State copying overhead
- Doesn't align with proven reducer patterns

### Migration Path

While Approach 1 is breaking, the migration is straightforward:

**Before (Async)**:
```swift
Interact(initialValue: State()) { state, action in
    switch action {
    case .increment:
        state.count += 1
        return .state
    case .fetch:
        state.isLoading = true
        return .perform { state, send in
            let data = await api.fetch()
            var newState = await state.current
            newState.data = data
            await send(newState)
        }
    }
}
```

**After (Sync)**:
```swift
Interact { state, action in
    switch action {
    case .increment:
        state.count += 1  // inout mutation
        return .state
    case .fetch:
        state.isLoading = true  // inout mutation
        return .perform { state, send in
            let data = await api.fetch()
            var newState = await state.current
            newState.data = data
            await send(newState)
        }
    }
}
```

**Changes**:
1. Remove `initialValue` (ViewModel owns initial state)
2. Handler signature unchanged (already used `inout State`)
3. Emission API unchanged

The migration is mechanical and can be automated with a script.

## Detailed Technical Design

### System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      SwiftUI View                        │
└────────────────────┬────────────────────────────────────┘
                     │ viewModel.sendViewEvent(.refresh)
                     ↓
┌─────────────────────────────────────────────────────────┐
│                       ViewModel                          │
│  @MainActor                                              │
│  1. let emission = interactor.interact(state: &state,    │
│                                        action: action)    │
│  2. Update viewState from domainState                    │
│  3. Spawn tasks from emission.kind                       │
│  4. Return EventTask(tasks)                              │
└────────────────────┬────────────────────────────────────┘
                     │ [SYNCHRONOUS CALL]
                     ↓
┌─────────────────────────────────────────────────────────┐
│                      Interactor                          │
│  (Interact, Merge, When, MergeMany)                      │
│  1. Process action (mutate state via inout)              │
│  2. Return Emission describing what to do                │
│     - .state: just emit state                            │
│     - .perform: spawn one effect                         │
│     - .observe: spawn long-running stream                │
│     - .merge: compose child emissions                    │
└─────────────────────────────────────────────────────────┘
                     │ [RETURNS IMMEDIATELY]
                     ↓
┌─────────────────────────────────────────────────────────┐
│                       Emission                           │
│  Kind: .state | .perform | .observe | .merge            │
│  Contains effect work closures (not yet executed)       │
└────────────────────┬────────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────────┐
│               ViewModel.spawnTasks()                     │
│  Recursively process emission:                           │
│  - .state: return []                                     │
│  - .perform: spawn Task { work(state, send) }           │
│  - .observe: spawn Task { stream(state, send) }         │
│  - .merge: flatMap children                             │
└────────────────────┬────────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────────┐
│                      EventTask                           │
│  Wraps Task that awaits all spawned effect tasks         │
│  - finish() → await all effects                          │
│  - cancel() → cancel all effects                         │
└─────────────────────────────────────────────────────────┘
```

### Component Design

#### 1. Core Interactor Protocol (BREAKING CHANGE)

**Purpose**: Define synchronous action processing contract.

**Implementation**:
```swift
/// A type that transforms **actions** into **emissions** by mutating **domain state**.
///
/// An `Interactor` is the core unit of business logic in Uno Architecture. Unlike the
/// previous stream-based design, interactors now work like reducers: they synchronously
/// process actions by mutating state and returning an `Emission` that describes any
/// effects to perform.
///
/// ## Declaring an Interactor
///
/// Use the `@Interactor` macro for concise declaration:
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor: Sendable {
///     var body: some InteractorOf<Self> {
///         Interact { state, action in
///             switch action {
///             case .increment:
///                 state.count += 1
///                 return .state
///             case .decrement:
///                 state.count -= 1
///                 return .state
///             }
///         }
///     }
/// }
/// ```
///
/// ## Effects
///
/// Return `.perform` or `.observe` emissions for async work:
///
/// ```swift
/// case .fetch:
///     state.isLoading = true
///     return .perform { state, send in
///         let data = try await api.fetchData()
///         var newState = await state.current
///         newState.isLoading = false
///         newState.data = data
///         await send(newState)
///     }
/// ```
///
/// ## Migration from Async API
///
/// The previous `interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State>` API
/// has been replaced with the synchronous `interact(state:action:)` API. This eliminates
/// the need for correlation infrastructure when returning `EventTask` from `sendViewEvent`.
public protocol Interactor<DomainState, Action> {
    /// The type of state managed by this interactor.
    associatedtype DomainState: Sendable

    /// The type of actions processed by this interactor.
    associatedtype Action: Sendable

    /// The concrete type returned by the result-builder `body` property.
    associatedtype Body: Interactor

    /// A declarative description of this interactor constructed with ``InteractorBuilder``.
    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    /// Processes an action by mutating state and returning an emission.
    ///
    /// This is the core method of the interactor system. It receives the current state
    /// as an `inout` parameter (allowing direct mutation) and an action to process.
    /// It returns an `Emission` describing what effects to perform.
    ///
    /// - Parameters:
    ///   - state: The current domain state (mutable).
    ///   - action: The action to process.
    /// - Returns: An `Emission` describing state changes and/or effects.
    func interact(state: inout DomainState, action: Action) -> Emission<DomainState>
}

extension Interactor where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension Interactor where Body: Interactor<DomainState, Action> {
    /// The default implementation forwards to the `body` interactor.
    public func interact(state: inout DomainState, action: Action) -> Emission<DomainState> {
        body.interact(state: &state, action: action)
    }
}

public typealias InteractorOf<I: Interactor> = Interactor<I.DomainState, I.Action>
```

**Why This Design**:
- **No `@MainActor` on protocol**: The protocol is actor-agnostic. Thread safety is enforced at the ViewModel level (which is `@MainActor`) and in the `Interact` handler signature.
- `inout State`: Makes state mutations explicit and efficient (no copying)
- Synchronous return: Enables immediate emission capture by ViewModel
- Body-based composition: Preserves existing result builder pattern
- `initialValue` requirement: Enables eager initialization in ViewModel (no deferred initialization complexity)

#### 2. Enhanced Emission with Merge

**Purpose**: Support composition of multiple emissions from higher-order interactors.

**Implementation**:
```swift
/// A descriptor that tells the ``ViewModel`` how to process an action's result.
///
/// `Emission` is returned from `Interactor.interact(state:action:)` to specify whether
/// state should be emitted synchronously or if async effects should be spawned.
///
/// ## Usage
///
/// There are four emission types:
///
/// ### `.state` - Synchronous Emission
///
/// Emits the mutated state immediately:
///
/// ```swift
/// Interact { state, action in
///     state.count += 1
///     return .state
/// }
/// ```
///
/// ### `.perform` - One-Shot Async Work
///
/// Spawns an async task and emits state via the `send` callback:
///
/// ```swift
/// return .perform { state, send in
///     let data = try await api.fetchData()
///     var currentState = await state.current
///     currentState.data = data
///     await send(currentState)
/// }
/// ```
///
/// ### `.observe` - Long-Running Observation
///
/// Spawns a long-lived task that observes a stream:
///
/// ```swift
/// return .observe { state, send in
///     for await location in locationManager.locations {
///         var currentState = await state.current
///         currentState.location = location
///         await send(currentState)
///     }
/// }
/// ```
///
/// ### `.merge` - Composition
///
/// Combines multiple emissions (used by higher-order interactors):
///
/// ```swift
/// return .merge([
///     emission1,  // From first child
///     emission2   // From second child
/// ])
/// ```
public struct Emission<State: Sendable>: Sendable {
    /// The kind of emission to perform.
    public enum Kind: Sendable {
        /// Immediately emit the mutated state.
        case state

        /// Execute an asynchronous unit of work and emit state via the `Send` callback.
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)

        /// Observe a stream, emitting state for each element via the `Send` callback.
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)

        /// Merge multiple emissions together (for higher-order interactors).
        ///
        /// The ViewModel will process all child emissions, spawning their tasks
        /// and collecting them into a single EventTask.
        case merge([Emission<State>])
    }

    let kind: Kind

    /// Creates an emission that immediately emits the current state.
    public static var state: Emission {
        Emission(kind: .state)
    }

    /// Creates an emission that executes async work and emits state via callback.
    public static func perform(
        _ work: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .perform(work: work))
    }

    /// Creates an emission that observes an async stream and emits state for each element.
    public static func observe(
        _ stream: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .observe(stream: stream))
    }

    /// Merges multiple emissions together.
    ///
    /// This is used by higher-order interactors like `Merge` and `MergeMany` to
    /// combine emissions from multiple children.
    ///
    /// - Parameter emissions: The emissions to merge.
    /// - Returns: A merged emission that will spawn all child effects.
    public static func merge(_ emissions: [Emission<State>]) -> Emission {
        Emission(kind: .merge(emissions))
    }

    /// Merges this emission with another.
    ///
    /// - Parameter other: Another emission to merge.
    /// - Returns: A merged emission containing both.
    public func merging(with other: Emission<State>) -> Emission<State> {
        .merge([self, other])
    }
}
```

**Why This Design**:
- `.merge` case: Enables composition without nested AsyncStreams
- Flat structure: No need for recursive emission types
- Backward compatible: Existing `.state`, `.perform`, `.observe` unchanged
- ViewModel processes: ViewModel recursively flattens `.merge` cases

#### 3. Simplified Interact

**Purpose**: Core primitive for handling actions, now synchronous and exposes initial state via protocol requirement.

**Implementation**:
```swift
/// The core primitive for handling actions and emitting state within an ``Interactor``.
///
/// `Interact` is the fundamental building block of the interactor system. It processes
/// actions synchronously through a handler closure that mutates state and returns an
/// ``Emission`` describing any effects to perform.
///
/// ## Basic Usage
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor: Sendable {
///     var body: some InteractorOf<Self> {
///         Interact(initialValue: CounterState()) { state, action in
///             switch action {
///             case .increment:
///                 state.count += 1
///                 return .state
///             case .decrement:
///                 state.count -= 1
///                 return .state
///             }
///         }
///     }
/// }
/// ```
///
/// ## Async Work Example
///
/// ```swift
/// Interact(initialValue: DataState()) { state, action in
///     switch action {
///     case .fetchData:
///         state.isLoading = true
///         return .perform { state, send in
///             let data = try await api.fetch()
///             var currentState = await state.current
///             currentState.isLoading = false
///             currentState.data = data
///             await send(currentState)
///         }
///     }
/// }
/// ```
public struct Interact<State: Sendable, Action: Sendable>: Interactor, @unchecked Sendable {
    /// The type of the handler closure that processes actions.
    public typealias Handler = (inout State, Action) -> Emission<State>

    private let _initialValue: State
    private let handler: Handler

    /// Creates an `Interact` primitive with the given initial state and handler.
    ///
    /// - Parameters:
    ///   - initialValue: The initial state value for the domain.
    ///   - handler: A closure that processes actions and returns an ``Emission``.
    public init(initialValue: State, handler: @escaping Handler) {
        self._initialValue = initialValue
        self.handler = handler
    }

    /// The initial state value, exposed via protocol requirement.
    public var initialValue: State { _initialValue }

    public var body: some Interactor<State, Action> { self }

    /// Processes an action by calling the handler.
    ///
    /// This method simply delegates to the handler closure, which mutates the state
    /// and returns an emission describing what effects to spawn.
    ///
    /// - Parameters:
    ///   - state: The current state (mutable).
    ///   - action: The action to process.
    /// - Returns: An emission describing state changes and/or effects.
    public func interact(state: inout State, action: Action) -> Emission<State> {
        handler(&state, action)
    }
}
```

**Why This Design**:
- **Exposes `initialValue`**: Accessible via protocol requirement for ViewModel initialization
- **No `@MainActor` on struct**: Only the handler is `@MainActor`-isolated
- **Eliminated complexity**: No StateBox, AsyncStream, continuation, effect task array
- **Just delegates**: Handler does all the work
- **State is `inout`**: Managed by caller (ViewModel directly)
- **Much simpler**: ~30 lines vs ~145 lines in async version

#### 4. Modified ViewModel

**Purpose**: Process actions synchronously, spawn tasks, return EventTask with event ID tracking.

**Implementation**:
```swift
/// A generic class that binds a SwiftUI view to your domain/business logic.
///
/// `ViewModel` coordinates between UI events and the interactor system. It now processes
/// actions synchronously, enabling immediate `EventTask` return from `sendViewEvent`.
///
/// ## Data Flow
///
/// 1. View calls `sendViewEvent(_:)` with user action
/// 2. ViewModel initializes domain state from interactor if `.waiting`
/// 3. ViewModel calls `interactor.interact(state:action:)` synchronously
/// 4. Interactor mutates state and returns `Emission`
/// 5. ViewModel updates view state from domain state
/// 6. ViewModel spawns effect tasks from emission, tracking by event ID
/// 7. ViewModel returns `EventTask` wrapping all spawned tasks
///
/// ## Usage
///
/// ```swift
/// struct CounterView: View {
///     @StateObject var viewModel: ViewModel<CounterAction, CounterState, CounterViewState>
///
///     var body: some View {
///         VStack {
///             Text("Count: \(viewModel.viewState.count)")
///             Button("Increment") {
///                 viewModel.sendViewEvent(.increment)
///             }
///             Button("Fetch") {
///                 Task {
///                     await viewModel.sendViewEvent(.fetch).finish()
///                 }
///             }
///         }
///         .refreshable {
///             await viewModel.sendViewEvent(.refresh).finish()
///         }
///     }
/// }
/// ```
@dynamicMemberLookup
@MainActor
public final class ViewModel<Action, DomainState, ViewState>: Observable, _ViewModel
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState {
    private var _viewState: ViewState
    private var domainBox: DomainBox<DomainState> = .waiting

    /// All in-flight effect tasks for lifecycle management.
    private var effectTasks: [Task<Void, Never>] = []

    private let interactor: AnyInteractor<DomainState, Action>
    private let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>

    private let _$observationRegistrar = ObservationRegistrar()

    /// Creates a ViewModel with separate domain and view state types.
    ///
    /// The domain state is initialized lazily from the interactor's `initialValue`
    /// on first action. Consumers only need to provide initial view state.
    ///
    /// - Parameters:
    ///   - initialValue: The initial view state value.
    ///   - interactor: The type-erased interactor that processes actions.
    ///   - viewStateReducer: The reducer that transforms domain state to view state.
    public init(
        initialValue: @autoclosure () -> ViewState,
        _ interactor: AnyInteractor<DomainState, Action>,
        _ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    ) {
        self._viewState = initialValue()
        self.interactor = interactor
        self.viewStateReducer = viewStateReducer
    }

    /// Creates a ViewModel where domain state equals view state (direct binding).
    ///
    /// - Parameters:
    ///   - initialValue: The initial state value (used for both domain and view).
    ///   - interactor: The type-erased interactor that processes actions.
    public init(
        _ initialValue: @autoclosure () -> ViewState,
        _ interactor: AnyInteractor<ViewState, Action>
    ) where DomainState == ViewState {
        self._viewState = initialValue()
        self.interactor = interactor
        // Identity reducer: domain state IS view state
        self.viewStateReducer = BuildViewState<ViewState, ViewState> { domainState, viewState in
            viewState = domainState
        }.eraseToAnyReducer()
    }

    public private(set) var viewState: ViewState {
        get {
            _$observationRegistrar.access(self, keyPath: \.viewState)
            return _viewState
        }
        set {
            if _viewState._$id == newValue._$id {
                _viewState = newValue
            } else {
                _$observationRegistrar.withMutation(of: self, keyPath: \.viewState) {
                    _viewState = newValue
                }
            }
        }
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<ViewState, Value>) -> Value {
        self.viewState[keyPath: keyPath]
    }

    /// Sends an event to the interactor and returns a task representing its lifecycle.
    ///
    /// This method synchronously processes the action, updates state, and spawns any
    /// effects. The returned `EventTask` can be awaited to ensure all effects complete.
    ///
    /// ## Usage
    ///
    /// Fire-and-forget (existing pattern):
    /// ```swift
    /// viewModel.sendViewEvent(.increment)
    /// ```
    ///
    /// Await completion:
    /// ```swift
    /// await viewModel.sendViewEvent(.refresh).finish()
    /// ```
    ///
    /// Cancellable:
    /// ```swift
    /// let task = viewModel.sendViewEvent(.longOperation)
    /// task.cancel()  // Cancel if needed
    /// ```
    ///
    /// - Parameter event: The action to send to the interactor.
    /// - Returns: An ``EventTask`` that can be awaited or cancelled.
    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask {
        // Domain state is always initialized - just use it directly
        var state = domainState

        // Synchronously process action
        let emission = interactor.interact(state: &state, action: event)

        // Update domain state
        domainState = state

        // Update view state from new domain state
        viewStateReducer.reduce(domainState, into: &viewState)

        // Spawn effect tasks from emission
        let tasks = spawnTasks(from: emission)

        // Track tasks for lifecycle management
        effectTasks.append(contentsOf: tasks)

        // Return EventTask wrapping all spawned tasks
        guard !tasks.isEmpty else {
            return EventTask(rawValue: nil)
        }

        let compositeTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for task in tasks {
                    group.addTask { await task.value }
                }
            }
            // Clean up completed tasks
            await MainActor.run {
                self?.effectTasks.removeAll { task in
                    tasks.contains { $0 === task }
                }
            }
        }

        return EventTask(rawValue: compositeTask)
    }

    /// Recursively spawns tasks from an emission.
    private func spawnTasks(from emission: Emission<DomainState>) -> [Task<Void, Never>] {
        switch emission.kind {
        case .state:
            return []

        case .perform(let work):
            let dynamicState = makeDynamicState()
            let send = makeSend()
            let task = Task {
                await work(dynamicState, send)
            }
            return [task]

        case .observe(let stream):
            let dynamicState = makeDynamicState()
            let send = makeSend()
            let task = Task {
                await stream(dynamicState, send)
            }
            return [task]

        case .merge(let emissions):
            return emissions.flatMap { spawnTasks(from: $0) }
        }
    }

    /// Creates a DynamicState that reads from current domain state.
    private func makeDynamicState() -> DynamicState<DomainState> {
        DynamicState { [weak self] in
            guard let self else {
                fatalError("ViewModel deallocated during effect execution")
            }
            return await MainActor.run { self.domainBox.unwrapped }
        }
    }

    /// Creates a Send callback that updates domain and view state.
    private func makeSend() -> Send<DomainState> {
        Send { [weak self] newState in
            guard let self else { return }
            self.domainBox = .active(newState)
            self.viewStateReducer.reduce(newState, into: &self.viewState)
        }
    }

    deinit {
        // Cancel all effect tasks when ViewModel is deallocated
        effectTasks.forEach { $0.cancel() }
    }
}

public typealias DirectViewModel<Action: Sendable, State: Sendable & ObservableState> = ViewModel<Action, State, State>
```

**Why This Design**:
- **Direct state storage**: No DomainBox enum, domain state initialized eagerly from `interactor.initialValue`
- **Synchronous processing**: `interactor.interact` called directly, no streams
- **Immediate state update**: Domain state and view state updated before spawning tasks
- **No correlation needed**: Tasks obtained immediately from emission
- **Recursive task spawning**: `.merge` emissions flattened automatically
- **Simple task tracking**: All effect tasks tracked in flat array for lifecycle management
- **Deinit cleanup**: All effects cancelled when ViewModel deallocates
- **Trust consumer**: ViewModel trusts consumer-provided initial ViewState, doesn't call reducer on init
- **Uses actual types**: `AnyViewStateReducer`, `BuildViewState`, proper observation registrar pattern

#### 5. Higher-Order Interactors with Merge

**Merge Implementation**:
```swift
extension Interactors {
    /// Combines two interactors into one, forwarding each action to both.
    ///
    /// `Merge` processes each action through both children and merges their emissions.
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     LoggingInteractor()
    ///     CounterInteractor()  // Merged with LoggingInteractor
    /// }
    /// ```
    @MainActor
    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor, Sendable
    where I0.DomainState: Sendable, I0.Action: Sendable {
        private let i0: I0
        private let i1: I1

        public init(_ i0: I0, _ i1: I1) {
            self.i0 = i0
            self.i1 = i1
        }

        public var body: some Interactor<I0.DomainState, I0.Action> { self }

        public func interact(state: inout I0.DomainState, action: I0.Action) -> Emission<I0.DomainState> {
            // Process action through first child
            let emission0 = i0.interact(state: &state, action: action)

            // Process action through second child (with updated state)
            let emission1 = i1.interact(state: &state, action: action)

            // Merge emissions
            return .merge([emission0, emission1])
        }
    }
}
```

**MergeMany Implementation**:
```swift
extension Interactors {
    /// Combines an array of interactors into one, forwarding each action to all.
    @MainActor
    public struct MergeMany<Element: Interactor>: Interactor, Sendable
    where Element.DomainState: Sendable, Element.Action: Sendable {
        private let interactors: [Element]

        public init(interactors: [Element]) {
            self.interactors = interactors
        }

        public var body: some Interactor<Element.DomainState, Element.Action> { self }

        public func interact(state: inout Element.DomainState, action: Element.Action) -> Emission<Element.DomainState> {
            // Process action through all children, collecting emissions
            let emissions = interactors.map { interactor in
                interactor.interact(state: &state, action: action)
            }

            // Merge all emissions
            return .merge(emissions)
        }
    }
}
```

**When Implementation** (more complex due to scoping):
```swift
extension Interactors {
    /// An interactor that scopes a child interactor to a subset of parent state and actions.
    @MainActor
    public struct When<Parent: Interactor & Sendable, Child: Interactor & Sendable>: Interactor, Sendable
    where
        Parent.DomainState: Sendable, Parent.Action: Sendable,
        Child.DomainState: Sendable, Child.Action: Sendable
    {
        public typealias DomainState = Parent.DomainState
        public typealias Action = Parent.Action

        enum StatePath: Sendable {
            case keyPath(WritableKeyPath<Parent.DomainState, Child.DomainState>)
            case casePath(AnyCasePath<Parent.DomainState, Child.DomainState>)
        }

        let parent: Parent
        let toChildState: StatePath
        let toChildAction: AnyCasePath<Parent.Action, Child.Action>
        let toStateAction: AnyCasePath<Parent.Action, Child.DomainState>
        let child: Child

        public var body: some Interactor<DomainState, Action> { self }

        public func interact(state: inout DomainState, action: Action) -> Emission<DomainState> {
            // Check if this action is for the child
            if let childAction = toChildAction.extract(from: action) {
                // Extract child state
                var childState: Child.DomainState
                switch toChildState {
                case .keyPath(let kp):
                    childState = state[keyPath: kp]
                case .casePath(let cp):
                    guard let extracted = cp.extract(from: state) else {
                        // Child state not present, just forward to parent
                        return parent.interact(state: &state, action: action)
                    }
                    childState = extracted
                }

                // Process child action
                let childEmission = child.interact(state: &childState, action: childAction)

                // Write child state back
                switch toChildState {
                case .keyPath(let kp):
                    state[keyPath: kp] = childState
                case .casePath(let cp):
                    // For case paths, need to create parent action with child state
                    let stateAction = toStateAction.embed(childState)
                    // Process that through parent
                    let parentEmission = parent.interact(state: &state, action: stateAction)
                    return .merge([childEmission, parentEmission])
                }

                // Return child emission (state already updated)
                return childEmission
            } else {
                // Not a child action, forward to parent
                return parent.interact(state: &state, action: action)
            }
        }
    }
}
```

**Why This Design**:
- Sequential processing: Each child sees updated state from previous child
- Emission merging: All child emissions collected and merged
- No streams: Direct function calls, state passed as `inout`
- Composition: `.merge` naturally flattens in ViewModel

### Testing Architecture

**Synchronous Testing**:
```swift
@Test
func testSyncAction() {
    var state = CounterState()
    let interactor = CounterInteractor()

    // Synchronous test, no awaiting needed
    let emission = interactor.interact(state: &state, action: .increment)

    #expect(state.count == 1)
    #expect(emission.kind == .state)
}

@Test
func testAsyncEffect() async {
    var state = DataState()
    let interactor = DataInteractor()

    let emission = interactor.interact(state: &state, action: .fetch)

    #expect(state.isLoading == true)

    // Emission should be .perform
    guard case .perform(let work) = emission.kind else {
        Issue.record("Expected .perform emission")
        return
    }

    // Spawn the task
    let task = Task {
        await work(
            DynamicState { state },
            Send { newState in state = newState }
        )
    }

    await task.value

    #expect(state.isLoading == false)
    #expect(state.data != nil)
}
```

**InteractorTestHarness Enhancement**:
```swift
@MainActor
public final class InteractorTestHarness<State: Sendable, Action: Sendable> {
    private var state: State
    private let interactor: AnyInteractor<State, Action>
    private var stateHistory: [State] = []
    private var effectTasks: [Task<Void, Never>] = []

    public init(
        initialState: State,
        _ interactor: AnyInteractor<State, Action>
    ) {
        self.state = initialState
        self.interactor = interactor
        self.stateHistory = [initialState]
    }

    /// Sends an action and returns a task representing its lifecycle.
    @discardableResult
    public func send(_ action: Action) -> EventTask {
        // Synchronously process action
        let emission = interactor.interact(state: &state, action: action)

        // Record state after synchronous processing
        stateHistory.append(state)

        // Spawn effect tasks
        let tasks = spawnTasks(from: emission)

        guard !tasks.isEmpty else {
            return EventTask(rawValue: nil)
        }

        let compositeTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for task in tasks {
                    group.addTask { await task.value }
                }
            }
        }

        return EventTask(rawValue: compositeTask)
    }

    /// Sends an action and awaits all effects.
    public func sendAndAwait(_ action: Action) async {
        await send(action).finish()
    }

    /// Sends multiple actions sequentially, awaiting each one's completion.
    public func sendSequentially(_ actions: Action...) async {
        for action in actions {
            await sendAndAwait(action)
        }
    }

    private func spawnTasks(from emission: Emission<State>) -> [Task<Void, Never>] {
        switch emission.kind {
        case .state:
            return []

        case .perform(let work):
            let dynamicState = DynamicState { [weak self] in
                guard let self else { fatalError() }
                return await self.state
            }
            let send = Send { [weak self] newState in
                guard let self else { return }
                self.state = newState
                self.stateHistory.append(newState)
            }
            let task = Task { await work(dynamicState, send) }
            effectTasks.append(task)
            return [task]

        case .observe(let stream):
            // Similar to .perform
            let task = Task { await stream(dynamicState, send) }
            effectTasks.append(task)
            return [task]

        case .merge(let emissions):
            return emissions.flatMap { spawnTasks(from: $0) }
        }
    }

    /// Asserts the state history matches expected values.
    public func assertStates(_ expected: [State]) throws where State: Equatable {
        guard stateHistory == expected else {
            Issue.record("State history mismatch:\n  Expected: \(expected)\n  Actual:   \(stateHistory)")
            throw TestError.stateHistoryMismatch
        }
    }

    /// Returns the current state.
    public var currentState: State {
        state
    }
}
```

**Why This Design**:
- Synchronous assertions: Can assert state immediately after `send()`
- Explicit awaiting: Must explicitly await effects via `sendAndAwait` or `.finish()`
- State history: Tracks all state changes (sync + async)
- Clean separation: Sync processing vs async effects

### Data Models

All core types:

```swift
// Interactor.swift
@MainActor
public protocol Interactor<DomainState, Action> {
    associatedtype DomainState: Sendable
    associatedtype Action: Sendable
    associatedtype Body: Interactor

    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    func interact(state: inout DomainState, action: Action) -> Emission<DomainState>
}

// Emission.swift
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        case state
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)
        case merge([Emission<State>])
    }

    let kind: Kind

    public static var state: Emission { Emission(kind: .state) }
    public static func perform(_ work: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void) -> Emission {
        Emission(kind: .perform(work: work))
    }
    public static func observe(_ stream: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void) -> Emission {
        Emission(kind: .observe(stream: stream))
    }
    public static func merge(_ emissions: [Emission<State>]) -> Emission {
        Emission(kind: .merge(emissions))
    }
}

// EventTask.swift
/// A handle to the effects spawned by a single `sendViewEvent` call.
///
/// Use `EventTask` to await completion of effects or cancel them.
///
/// ```swift
/// // Fire-and-forget
/// viewModel.sendViewEvent(.increment)
///
/// // Await completion
/// await viewModel.sendViewEvent(.fetch).finish()
///
/// // Cancel
/// let task = viewModel.sendViewEvent(.longOperation)
/// task.cancel()
/// ```
public struct EventTask: Sendable {
    internal let rawValue: Task<Void, Never>?

    internal init(rawValue: Task<Void, Never>?) {
        self.rawValue = rawValue
    }

    /// Cancels all effects spawned by this event.
    public func cancel() {
        rawValue?.cancel()
    }

    /// Awaits completion of all effects spawned by this event.
    @discardableResult
    public func finish() async {
        await rawValue?.value
    }

    /// Whether this event's effects have been cancelled.
    public var isCancelled: Bool {
        rawValue?.isCancelled ?? false
    }

    /// Whether this event spawned any effects.
    public var hasEffects: Bool {
        rawValue != nil
    }
}

// DynamicState.swift (unchanged)
@dynamicMemberLookup
public struct DynamicState<State>: Sendable {
    private let getCurrentState: @Sendable () async -> State

    init(getCurrentState: @escaping @Sendable () async -> State) {
        self.getCurrentState = getCurrentState
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<State, T>) -> T {
        get async { await getCurrentState()[keyPath: keyPath] }
    }

    public var current: State {
        get async { await getCurrentState() }
    }
}

// Send.swift (unchanged)
@MainActor
public struct Send<State: Sendable>: Sendable {
    private let yield: @MainActor (State) -> Void

    init(_ yield: @escaping @MainActor (State) -> Void) {
        self.yield = yield
    }

    public func callAsFunction(_ state: State) {
        guard !Task.isCancelled else { return }
        yield(state)
    }
}
```

### Scalability & Performance

**Performance Improvements**:
1. **No AsyncStream overhead**: Direct function calls, no continuation management
2. **No action queueing**: Actions processed immediately when sent
3. **Explicit state updates**: `inout` mutation is efficient, no copying
4. **Immediate task availability**: No 10ms delay for task registration

**Benchmarks** (projected):
- Current async: ~50μs per action (stream + continuation overhead)
- Proposed sync: ~5μs per action (direct function call + emission creation)
- **10x faster** for synchronous actions

**Memory**:
- Eliminated: StateBox, action continuations, stream buffers
- Added: Emission allocations (minimal, struct with enum)
- Net: Significant reduction in memory overhead

### Reliability & Security

**Thread Safety**:
- `@MainActor` isolation: All interactor and ViewModel methods isolated
- `inout State`: Safe because all access is serialized on main actor
- Effect tasks: Spawn on main actor, can safely capture state via DynamicState

**Error Handling**:
```swift
// Effects can throw, caller handles
case .fetch:
    state.isLoading = true
    return .perform { state, send in
        do {
            let data = try await api.fetch()
            var newState = await state.current
            newState.isLoading = false
            newState.data = data
            await send(newState)
        } catch {
            var newState = await state.current
            newState.isLoading = false
            newState.error = error
            await send(newState)
        }
    }
```

**Cancellation**:
- EventTask cancellation: Propagates to all spawned effect tasks
- ViewModel deinit: Cancels all in-flight effects
- Proper cleanup: Effect tasks checked for cancellation before emitting

### Migration Strategy

Since the library is in alpha, we do a **direct replacement** without backward compatibility.

**Migration Steps**:
1. Update `Interactor` protocol to sync signature
2. Update `AnyInteractor` to sync signature and expose `initialValue`
3. Rewrite `Interact` to sync (keeping `initialValue`)
4. Rewrite `ViewModel` to use DomainBox and sync processing
5. Rewrite higher-order interactors (Merge, When, MergeMany)
6. Update all tests

**Code Changes for Consumers**:

The handler signature is unchanged - consumers just need to update protocol conformance:

```swift
// Before: AsyncStream-based (implicit)
Interact(initialValue: CounterState()) { state, action in
    switch action {
    case .increment:
        state.count += 1
        return .state
    }
}

// After: Sync-based (same handler code!)
Interact(initialValue: CounterState()) { state, action in
    switch action {
    case .increment:
        state.count += 1
        return .state
    }
}
```

**What Changes**:
- Internal implementation of `Interact` (simplified)
- `ViewModel` initialization (no domain state required from consumer)
- `sendViewEvent` returns `EventTask` with ID

**What Stays the Same**:
- `Interact(initialValue:handler:)` API
- Handler signature `(inout State, Action) -> Emission`
- Emission types (`.state`, `.perform`, `.observe`)
- `DynamicState` and `Send` usage in effects

## Implementation Roadmap

### Phase 1: Core Sync API (Breaking)

**Goal**: Implement synchronous Interactor protocol and basic functionality.

**Tasks**:
- [ ] Update `Interactor` protocol to sync signature
- [ ] Add `.merge` case to `Emission`
- [ ] Simplify `Interact` to synchronous handler
- [ ] Update `ViewModel` to process actions synchronously
- [ ] Update `Merge`, `MergeMany` to sync
- [ ] Remove `StateBox` (no longer needed)

**Files**:
- `Sources/UnoArchitecture/Domain/Interactor.swift` (modify protocol)
- `Sources/UnoArchitecture/Domain/Emission.swift` (add .merge)
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift` (simplify)
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift` (rewrite)
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/Merge.swift` (rewrite)
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/MergeMany.swift` (rewrite)
- `Sources/UnoArchitecture/Internal/StateBox.swift` (delete)

**Testing**:
- Unit tests: Synchronous interact calls
- Integration tests: ViewModel + Interact
- Composition tests: Merge emissions

### Phase 2: EventTask Integration

**Goal**: EventTask becomes trivial with sync API.

**Tasks**:
- [ ] Simplify EventTask implementation (no ActionContext needed)
- [ ] Update `sendViewEvent` to return EventTask naturally
- [ ] Remove correlation infrastructure (ActionContext, task-locals)
- [ ] Update examples with `.refreshable`

**Files**:
- `Sources/UnoArchitecture/Presentation/ViewModel/EventTask.swift` (simplify)
- `Sources/UnoArchitecture/Presentation/ViewModel/ViewModel.swift` (return EventTask)

**Testing**:
- EventTask tests: Awaiting effects
- SwiftUI integration tests: `.refreshable`

### Phase 3: Higher-Order Interactors

**Goal**: Complete When implementation, verify composition.

**Tasks**:
- [ ] Rewrite `When` for sync API
- [ ] Add tests for deep composition (Merge + When + Interact)
- [ ] Verify state scoping works correctly

**Files**:
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift` (rewrite)

**Testing**:
- When tests: Child action routing
- Composition tests: Nested higher-order interactors

### Phase 4: Testing Infrastructure

**Goal**: Enhanced test harness with sync benefits.

**Tasks**:
- [ ] Update `InteractorTestHarness` for sync API
- [ ] Add state history assertions
- [ ] Add `sendAndAwait` helper
- [ ] Update example tests

**Files**:
- `Sources/UnoArchitecture/Testing/InteractorTestHarness.swift` (rewrite)

**Testing**:
- Test harness tests
- Example interactor tests

### Phase 5: Documentation & Migration

**Goal**: Comprehensive docs and migration guides.

**Tasks**:
- [ ] Update all DocC documentation
- [ ] Write migration guide
- [ ] Create automated migration script
- [ ] Update README and examples
- [ ] Record migration video tutorial

**Files**:
- All source files (DocC comments)
- `docs/migration/sync-interactor-migration.md` (new)
- `scripts/migrate-to-sync-api.sh` (new)
- `README.md` (update)

## Trade-offs vs Current Architecture

### Advantages of Sync API

1. **Simpler Mental Model**:
   - Before: "Actions go into a stream, somewhere downstream effects spawn"
   - After: "Call a function, get emission, spawn tasks"

2. **No Correlation Infrastructure**:
   - Before: Would need ActionContext, task-locals, 10ms delays, sealing
   - After: Emission returned immediately, tasks extracted directly with event ID

3. **Better Testing**:
   - Before: Await arbitrary delays, hope effects spawned
   - After: Synchronous assertions, explicit effect awaiting

4. **Performance**:
   - Before: AsyncStream overhead, continuation management
   - After: Direct function calls, minimal overhead

5. **Clearer State Management**:
   - Before: StateBox hidden inside stream closure
   - After: Direct state storage in ViewModel, no boxing/wrapping

6. **Industry Alignment**:
   - Reducer pattern is proven (TCA, Elm, Redux)
   - Familiar to many developers

7. **Clean Initialization**:
   - Interactor provides initial domain state via protocol requirement
   - ViewModel initializes eagerly (fails fast if initialization fails)
   - Consumer provides initial ViewState separately

8. **Simple Cancellation Model**:
   - `EventTask.cancel()` cancels a specific event's effects
   - ViewModel cancels all effects on deinit
   - No complex ID tracking needed

### Considerations

1. **No Natural Backpressure**:
   - Actions processed immediately
   - UI-driven actions rarely need backpressure
   - Can rate-limit in View layer if needed

2. **Eager Initialization**:
   - ViewModel initializes domain state immediately on construction
   - Fails fast if interactor initialization fails
   - This is actually a benefit (early error detection)

### Initial State Solution: Protocol Requirement with Eager Initialization

After analyzing the problem, the cleanest solution is **Option A: Add `initialValue` property to `Interactor` protocol** with thoughtful handling for composition and **eliminating DomainBox entirely**.

#### Problem Analysis

The synchronous API creates a chicken-and-egg problem:
1. `Interact(initialValue: State())` defines initial state
2. ViewModel needs `DomainBox.waiting` → `.active(initialState)` transition
3. `AnyInteractor` type-erases the interactor, losing access to `initialValue`
4. The sync API has no "start" action - initial state must be available before first action

Current `Interact` implementation:
```swift
public struct Interact<State: Sendable, Action: Sendable>: Interactor {
    private let initialValue: State  // Not accessible after type erasure!

    public init(initialValue: State, handler: @escaping Handler) {
        self.initialValue = initialValue
        self.handler = handler
    }
}
```

After `eraseToAnyInteractor()`, the `initialValue` is trapped inside a closure and inaccessible.

#### Evaluation of Options

**Option A: Protocol Requirement**
```swift
public protocol Interactor<DomainState, Action> {
    var initialValue: DomainState { get }
    func interact(state: inout DomainState, action: Action) -> Emission<DomainState>
}
```

**Pros**:
- Clean, explicit contract: "Every interactor provides its initial state"
- Accessible through `AnyInteractor` without special handling
- Works naturally with higher-order interactors (they compute from children)
- Follows Swift protocol best practices

**Cons**:
- Breaks existing pattern of `body`-only implementations
- Requires default implementation for custom interactors
- Minor syntactic overhead

**Option B: InitializableInteractor Protocol**
```swift
public protocol InitializableInteractor: Interactor {
    var initialValue: DomainState { get }
}
```

**Pros**:
- Separate concern: not all interactors need initialization
- More flexible for advanced use cases

**Cons**:
- **Fatal flaw**: ViewModel uses `AnyInteractor<State, Action>`, not specific types
- Would need `AnyInitializableInteractor` wrapper and runtime casting
- Composition breaks: `Merge` of `InitializableInteractor + Interactor` loses type info
- Adds complexity without clear benefit

**Option C: Startup Action Pattern**
```swift
// ViewModel synthesizes a .startup action on initialization
domainBox = .active(interactor.interact(state: &initialState, action: .startup))
```

**Pros**:
- No protocol changes needed
- Actions control everything

**Cons**:
- **Fatal flaw**: Requires `Action` to have a `.startup` case (breaks generic code)
- Pollutes action space with framework concerns
- Users must handle `.startup` in every interactor
- Violates separation of concerns (framework vs domain logic)
- Doesn't work for custom `interact()` implementations that don't use `Interact`

#### Recommended Solution: Protocol Requirement + Eliminate DomainBox

Add `initialValue` as a protocol requirement with a default implementation that computes from `body`, and initialize domain state eagerly in ViewModel:

```swift
public protocol Interactor<DomainState, Action> {
    associatedtype DomainState: Sendable
    associatedtype Action: Sendable
    associatedtype Body: Interactor

    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    /// The initial domain state for this interactor.
    ///
    /// For most interactors, this is automatically computed from the `body`.
    /// Override this property only for custom `interact(_:)` implementations
    /// that don't use `Interact` or when you need custom initialization logic.
    var initialValue: DomainState { get }

    func interact(state: inout DomainState, action: Action) -> Emission<DomainState>
}

extension Interactor where Body: Interactor<DomainState, Action> {
    /// Default: Delegate to body's initialValue
    public var initialValue: DomainState {
        body.initialValue
    }
}

extension Interactor where Body == Never {
    /// For custom implementations without a body, you must provide initialValue
    public var initialValue: DomainState {
        fatalError("'\(Self.self)' must implement 'initialValue' when providing a custom 'interact(state:action:)' implementation.")
    }
}
```

**How This Solves Each Case**:

1. **`Interact` (the primitive)**:
```swift
public struct Interact<State: Sendable, Action: Sendable>: Interactor {
    private let _initialValue: State

    public init(initialValue: State, handler: @escaping Handler) {
        self._initialValue = initialValue
        self.handler = handler
    }

    // Expose as protocol requirement
    public var initialValue: State { _initialValue }

    public var body: some Interactor<State, Action> { self }
}
```

2. **`Merge` (higher-order composition)**:
```swift
public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor {
    private let i0: I0
    private let i1: I1

    // Merge uses first child's initial state
    // (Both children share same State type, so they should have compatible initial states)
    public var initialValue: I0.DomainState {
        i0.initialValue
    }

    public func interact(state: inout I0.DomainState, action: I0.Action) -> Emission<I0.DomainState> {
        let emission0 = i0.interact(state: &state, action: action)
        let emission1 = i1.interact(state: &state, action: action)
        return .merge([emission0, emission1])
    }
}
```

3. **`When` (scoped composition)**:
```swift
public struct When<Parent: Interactor, Child: Interactor>: Interactor {
    let parent: Parent
    let child: Child
    // ... path properties

    // When uses parent's initial state (child is scoped)
    public var initialValue: Parent.DomainState {
        parent.initialValue
    }
}
```

4. **`MergeMany` (array composition)**:
```swift
public struct MergeMany<Element: Interactor>: Interactor {
    private let interactors: [Element]

    // Use first interactor's initial state, or require explicit initialization
    public var initialValue: Element.DomainState {
        guard let first = interactors.first else {
            fatalError("MergeMany requires at least one interactor")
        }
        return first.initialValue
    }
}
```

5. **Custom implementations**:
```swift
@Interactor<MyState, MyAction>
struct CustomInteractor {
    // Must provide initialValue for custom implementation
    var initialValue: MyState {
        MyState(customInitialization: true)
    }

    func interact(state: inout MyState, action: MyAction) -> Emission<MyState> {
        // Custom logic without using Interact
    }
}
```

6. **`AnyInteractor` (type erasure)**:
```swift
public struct AnyInteractor<State: Sendable, Action: Sendable>: Interactor, Sendable {
    private let _initialValue: State
    private let interactFunc: @Sendable (inout State, Action) -> Emission<State>

    public init<I: Interactor & Sendable>(_ base: I) where I.DomainState == State, I.Action == Action {
        self._initialValue = base.initialValue  // Capture at initialization!
        self.interactFunc = { state, action in base.interact(state: &state, action: action) }
    }

    public var initialValue: State { _initialValue }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action) -> Emission<State> {
        interactFunc(&state, action)
    }
}
```

7. **ViewModel initialization (WITHOUT DomainBox)**:
```swift
@MainActor
public final class ViewModel<Action, DomainState, ViewState> {
    private var domainState: DomainState  // Direct storage, no DomainBox!
    private let interactor: AnyInteractor<DomainState, Action>
    private let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>

    public init(
        initialValue: @autoclosure () -> ViewState,
        _ interactor: AnyInteractor<DomainState, Action>,
        _ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    ) {
        self.interactor = interactor
        self.viewStateReducer = viewStateReducer

        // Initialize domain state from interactor
        self.domainState = interactor.initialValue

        // ViewModel already receives initial view state from consumer
        // No need to call reducer on initialization - consumer provided the correct initial value
        self._viewState = initialValue()
    }

    public func sendViewEvent(_ event: Action) -> EventTask {
        // No more DomainBox conditional logic - just use domainState directly!
        var state = domainState
        let emission = interactor.interact(state: &state, action: event)
        domainState = state

        // Update view state from new domain state
        viewStateReducer.reduce(state, into: &viewState)

        // ... spawn tasks and return EventTask
    }
}
```

#### Why This is the Right Solution

1. **Explicit Contract**: The protocol clearly states "every interactor provides initial state"
2. **Zero Overhead**: Body-based interactors delegate automatically, no duplication
3. **Type-Safe Composition**: Higher-order interactors compute initial state from children
4. **Clean Type Erasure**: `AnyInteractor` captures `initialValue` at initialization time
5. **No Magic**: No synthetic actions, no runtime casting, no Optional unwrapping
6. **Fail-Fast**: Custom implementations without `initialValue` crash with clear error message
7. **Future-Proof**: Works with any composition pattern (current and future)
8. **Simpler ViewModel**: No DomainBox enum, no `.waiting` state, no conditional initialization
9. **Trust Consumer**: ViewModel trusts that consumer provides correct initial ViewState - no redundant reducer call
10. **No Fatal Error Paths**: Domain state is always valid (no unwrapping, no waiting state)

#### DomainBox Elimination Benefits

With `initialValue` in the protocol, we eliminate `DomainBox` entirely:

**Before (with DomainBox)**:
```swift
private var domainBox: DomainBox<DomainState> = .waiting

public func sendViewEvent(_ event: Action) -> EventTask {
    if case .waiting = domainBox {
        domainBox = .active(interactor.initialValue)  // Conditional initialization
    }

    guard case .active(var domainState) = domainBox else {
        fatalError("Should never happen")  // Fatal error path!
    }
    // ... rest
}
```

**After (direct initialization)**:
```swift
private var domainState: DomainState

public init(...) {
    self.domainState = interactor.initialValue  // Eager initialization
    self._viewState = initialValue()
    // No reducer call - consumer provided correct initial value
}

public func sendViewEvent(_ event: Action) -> EventTask {
    var state = domainState  // Always valid!
    // ... rest
}
```

**Trade-offs**:
- **Pro**: Simpler - no DomainBox enum, no `.waiting` state, no conditional initialization
- **Pro**: No fatal error paths (domain state always valid)
- **Pro**: Clearer initialization contract (interactor provides domain, consumer provides view)
- **Pro**: Easier to reason about (no state machine in ViewModel)
- **Con**: ViewModel initialization is slightly more eager (computes initial state immediately)
  - **Counter**: This is actually a pro - fails fast if interactor initialization fails
  - **Counter**: Initialization is lightweight (just calling a property getter)

### Updated Design Decision

**Final Recommendation**:
1. Add `initialValue: DomainState { get }` to `Interactor` protocol
2. Provide default implementation that delegates to `body.initialValue`
3. `Interact` exposes its stored `initialValue` as a computed property
4. Higher-order interactors compute `initialValue` from children
5. `AnyInteractor` captures `initialValue` at initialization
6. **Eliminate `DomainBox` entirely** - ViewModel initializes domain state eagerly from `interactor.initialValue`
7. **Trust consumer's initial ViewState** - Don't call `viewStateReducer` on initialization since consumer already provided the correct initial value

This solution is clean, type-safe, composable, eliminates an entire class of runtime errors (accessing `.waiting` state), and respects the separation of concerns (interactor provides domain, consumer provides view).

## Resolved Design Questions

1. **Initial State Handling**: ~~Should ViewModel accept `initialState` or compute from interactor?~~
   - **RESOLVED**: Interactor provides `initialValue` via protocol requirement. ViewModel initializes domain state from `interactor.initialValue` on init. Consumer provides initial ViewState separately (no redundant reducer call).

2. **DomainBox Pattern**: ~~Do we need DomainBox with `.waiting` state?~~
   - **RESOLVED**: No, eliminated entirely. With `initialValue` accessible from `AnyInteractor`, ViewModel can initialize domain state eagerly. This eliminates conditional logic and fatal error paths.

3. **State Observation**: How should long-running `.observe` emissions work?
   - **RESOLVED**: Same as `.perform`, just semantic difference (long-lived task)

4. **Emission Flattening**: Should `.merge` emissions be automatically flattened?
   - **RESOLVED**: Yes, ViewModel recursively flattens for simplicity

5. **Error Propagation**: Should emissions carry error information?
   - **RESOLVED**: No, errors handled within effect closures (current pattern)

6. **Testing Assertions**: Should harness auto-record all state changes from effects?
   - **RESOLVED**: Yes, record in `stateHistory` for easy assertions

## References

### The Composable Architecture
- [TCA Reducer](https://github.com/pointfreeco/swift-composable-architecture) - Similar synchronous reducer pattern
- [TCA Effects](https://pointfreeco.github.io/swift-composable-architecture/main/documentation/composablearchitecture/effects) - Effect composition patterns

### Elm Architecture
- [Elm Update Function](https://guide.elm-lang.org/architecture/) - Original synchronous update pattern
- [Elm Effects](https://guide.elm-lang.org/effects/) - Command-based effects

### Redux
- [Redux Reducers](https://redux.js.org/tutorials/fundamentals/part-3-state-actions-reducers) - Pure reducer functions
- [Redux-Saga](https://redux-saga.js.org/) - Effect management

### Martin Fowler
- [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html) - Event-driven state changes
- [Command Pattern](https://refactoring.guru/design-patterns/command) - Encapsulating requests

### Related Uno Documentation
- EventTask System Design: `thoughts/shared/research/2025-01-02_event_task_system_design.md`
- Current Interactor: `Sources/UnoArchitecture/Domain/Interactor.swift`
- Current Interact: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift`

---

## Addendum: Optional Enhancements

### A. ViewModel Re-Initialization Detection (Optional)

**Problem**: Consumers who don't use `@State` (or `@StateObject` for pre-Observation codebases) may accidentally create ViewModels as plain stored properties:

```swift
struct MyView: View {
    let viewModel = ViewModel(...)  // ❌ Re-created on each SwiftUI view re-init
}
```

SwiftUI can re-initialize view structs multiple times, creating duplicate ViewModels while the previous one still exists. This causes:
- Redundant `interactor.initialValue` computation
- Lost state (previous ViewModel deallocated)
- Cancelled in-flight tasks

**Solution**: Track ViewModel instances by call site and warn when duplicates are detected.

```swift
#if DEBUG
private let _viewModelRegistryLock = NSLock()
private var _viewModelRegistry: Set<String> = []
#endif

@MainActor
public final class ViewModel<Action, DomainState, ViewState> {

    #if DEBUG
    private let _registryKey: String
    #endif

    public init(
        initialValue: @autoclosure () -> ViewState,
        _ interactor: AnyInteractor<DomainState, Action>,
        _ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        #if DEBUG
        self._registryKey = "\(file):\(line)"

        _viewModelRegistryLock.withLock {
            if _viewModelRegistry.contains(_registryKey) {
                reportIssue(
                    """
                    ViewModel initialized at \(file):\(line) while a previous instance still exists.

                    This usually means the ViewModel is a stored property without @State:

                      struct MyView: View {
                          let viewModel = ViewModel(...)  // ❌ Re-created on view re-init
                      }

                    Fix by using @State:

                      struct MyView: View {
                          @State var viewModel = ViewModel(...)  // ✅ Created once
                      }
                    """
                )
            }
            _viewModelRegistry.insert(_registryKey)
        }
        #endif

        // ... rest of init
    }

    deinit {
        #if DEBUG
        let key = _registryKey
        _viewModelRegistryLock.withLock {
            _viewModelRegistry.remove(key)
        }
        #endif

        effectTasks.forEach { $0.cancel() }
    }
}
```

**How it works**:
1. **Init**: Generate key from `#fileID:#line`, check if key exists in global registry
   - If exists → another ViewModel from same call site is alive → `reportIssue`
   - Insert key into registry
2. **Deinit**: Remove key from registry

**Benefits**:
- Zero overhead in release builds (`#if DEBUG`)
- Clear diagnostic message with fix suggestion
- Catches misuse early in development
- Uses `reportIssue` for Xcode runtime warning integration (via swift-issue-reporting)

**Trade-offs**:
- Adds small DEBUG-only overhead
- Requires lock for thread safety in deinit
- False positive if legitimately creating multiple ViewModels at same call site (rare)

---

**Document Status**: COMPLETE
**Next Steps**: Review with team, validate approach, prototype Phase 1
**Breaking Change**: Yes, requires major version bump (2.0)
