# MainActor Isolation and Send Callback Pattern

Last Updated: 2025-12-30

## Overview

This document details the actor isolation strategy for the AsyncStream-based Interactor system. The design draws inspiration from TCA's (The Composable Architecture) approach to effect handling, specifically their `Send` callback pattern.

**Key decisions:**
- Mark `Interactor` protocol and `Interact` primitive as `@MainActor`
- Mark `ViewStateReducer` protocol and primitives as `@MainActor`
- Use a `Send` callback for effects to emit state updates back to the main actor
- Avoid `Task.detached` entirely by leveraging Swift's natural actor isolation rules
- Eliminate `StateActor` in favor of a simpler `StateBox` class

---

## Problem Statement

When migrating from Combine to AsyncStream, we need a clear strategy for:

1. **State mutation isolation** - Where do state updates occur?
2. **Background work execution** - How do we offload API calls and stream iteration?
3. **State emission from effects** - How do background tasks update state?

The naive approach uses `Task.detached` with `MainActor.run` callbacks, but this is verbose and breaks structured concurrency.

---

## TCA's Solution: The Send Pattern

TCA's `Effect.run` uses a clever pattern:

```swift
// TCA's Effect.run signature
static func run(
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable (Send<Action>) async -> Void
) -> Effect<Action>

// Send is @MainActor - the ONLY thing that needs main thread
@MainActor
public struct Send<Action>: Sendable {
    let send: @MainActor @Sendable (Action) -> Void

    public func callAsFunction(_ action: Action) {
        guard !Task.isCancelled else { return }
        send(action)
    }
}
```

**The insight**: The async work closure is NOT actor-isolated, so it naturally runs on the cooperative thread pool. Only the `Send` callback is `@MainActor`.

---

## Our Adapted Pattern

### The Send Type

```swift
/// A callback for emitting state updates from effects.
///
/// `Send` is `@MainActor` isolated, ensuring all state mutations
/// occur on the main thread. When called from a non-isolated async
/// context (like an effect closure), Swift automatically handles
/// the actor hop.
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

### Revised Emission Type

```swift
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        /// Synchronous state update - already applied to state
        case state

        /// Async work that emits state via Send callback.
        /// The closure runs on the cooperative thread pool (NOT main actor).
        /// Call `await send(newState)` to emit state updates.
        case perform(
            work: @Sendable (Send<State>) async -> Void
        )

        /// Observes a stream, emitting state for each element.
        /// The closure runs on the cooperative thread pool.
        /// Use `currentState.current` to access current state.
        case observe(
            stream: @Sendable (DynamicState<State>, Send<State>) async -> Void
        )
    }

    let kind: Kind

    public static var state: Emission { Emission(kind: .state) }

    public static func perform(
        _ work: @escaping @Sendable (Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .perform(work: work))
    }

    public static func observe(
        _ stream: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
    ) -> Emission {
        Emission(kind: .observe(stream: stream))
    }
}
```

### StateBox for Shared State

```swift
/// Holds mutable state accessible from effect callbacks.
/// MainActor-isolated for thread safety.
@MainActor
final class StateBox<State>: @unchecked Sendable {
    var value: State

    init(_ initial: State) {
        self.value = initial
    }
}
```

### Interact Implementation

```swift
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

    public func interact(
        _ upstream: AsyncStream<Action>
    ) -> AsyncStream<State> {
        AsyncStream { continuation in
            Task { @MainActor in
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
                        let task = Task {
                            await work(send)
                        }
                        effectTasks.append(task)

                    case .observe(let streamWork):
                        let dynamicState = DynamicState {
                            await MainActor.run { stateBox.value }
                        }
                        let task = Task {
                            await streamWork(dynamicState, send)
                        }
                        effectTasks.append(task)
                    }
                }

                // Cleanup on upstream completion
                effectTasks.forEach { $0.cancel() }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                // Handle external cancellation if needed
            }
        }
    }
}
```

---

## Why This Works

Swift's concurrency model has specific rules for actor isolation:

1. **`@MainActor` Task inherits isolation** - but only for the immediate closure
2. **Non-isolated async functions run on cooperative pool** - this is the default
3. **Calling `@MainActor` methods from non-isolated context** - automatically hops

When we write:

```swift
Task { @MainActor in
    // We're on main actor here

    let task = Task {
        // This closure is NOT @MainActor (no annotation)
        // Swift schedules it on the cooperative thread pool
        await work(send)  // work runs on background
    }
}
```

The inner `Task` is **unstructured** and its closure lacks `@MainActor` annotation, so Swift runs it on the cooperative thread pool. When `work` calls `await send(state)`, Swift handles the actor hop automatically.

---

## Usage Examples

### Simple State Transition

```swift
case .incrementCount:
    state.count += 1
    return .state
```

### Async API Call

```swift
case .fetchUsers:
    state.isLoading = true

    return .perform { send in
        // Runs on cooperative thread pool (NOT main thread)
        do {
            let users = try await apiClient.fetchUsers()
            // Hops to main actor automatically
            await send(State(users: users, isLoading: false, error: nil))
        } catch {
            await send(State(users: [], isLoading: false, error: error))
        }
    }
```

### Observing a Hot Stream

```swift
case .startListening:
    return .observe { currentState, send in
        // Iteration happens on cooperative thread pool
        for await event in websocketStream {
            // Access current state (hops to main actor)
            let current = await currentState.current

            // Build new state
            var items = current.items
            items.append(event)

            // Emit (hops to main actor)
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

                return .perform { send in
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

---

## Comparison: Task.detached vs Send Pattern

| Aspect | Task.detached | Send Pattern |
|--------|---------------|--------------|
| Background execution | Explicit | Implicit (default for non-isolated async) |
| Main actor hop | `await MainActor.run { }` | `await send(state)` |
| Boilerplate | High | Low |
| Cancellation handling | Manual check | Built into Send |
| Structured concurrency | No (unstructured) | Yes (regular Task) |
| Code at call site | Verbose | Clean |

### Before (Task.detached)

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

### After (Send Pattern)

```swift
case .perform(let work):
    let task = Task {
        await work(send)
    }
    effectTasks.append(task)
```

---

## ViewStateReducer Integration

With `@MainActor` interactors, the view state reducer becomes a simple synchronous transform:

```swift
@MainActor
public protocol ViewStateReducer {
    associatedtype DomainState
    associatedtype ViewState

    func reduce(_ domainState: DomainState) -> ViewState
}

// In ViewModel
Task { @MainActor in
    for await domainState in interactor.interact(actionStream) {
        self.viewState = reducer.reduce(domainState)
    }
}
```

No Combine publishers or complex async transformations needed.

---

## Migration Notes

### Changes from system-design.md

1. **Emission API Change**: `.perform` and `.observe` now take `Send<State>` callback instead of returning state directly
2. **No StateActor**: Replaced with simpler `StateBox` class
3. **Handler Signature**: Unchanged - still `(inout State, Action) -> Emission<State>`

### Backward Compatibility

The handler signature remains the same, but the `Emission` factory methods change:

```swift
// Old (returning state directly)
return .perform {
    let data = await api.fetch()
    return State(data: data)
}

// New (using Send callback)
return .perform { send in
    let data = await api.fetch()
    await send(State(data: data))
}
```

This is a breaking change, but since the library is under initial development, migration is straightforward.

---

## Open Questions

1. **Error Handling in Send**: Should `Send` accept `Result<State, Error>` for error propagation?
2. **Multiple Emissions**: Current design allows multiple `send()` calls per effect - is this desirable?
3. **Effect Identification**: Should effects have IDs for targeted cancellation (like TCA)?
4. **Animation Support**: TCA's Send supports `animation` and `transaction` - do we need this?

---

## References

- [TCA Effect.swift](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Effect.swift)
- [TCA Store.swift](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Store.swift)
- [Swift Concurrency: Actor Isolation](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
