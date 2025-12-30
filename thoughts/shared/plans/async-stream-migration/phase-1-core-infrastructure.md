# Phase 1: Core Infrastructure - Implementation Plan

## Overview

**Goal**: Build the foundational types for AsyncStream-based interactors, replacing the current Combine-based implementation.

**Scope**: This phase implements the core primitives only, not higher-order interactors (Phase 2) or testing infrastructure (Phase 3).

## Current State Analysis

**Current Combine-Based Architecture**:
- `Interactor` protocol: `func interact(_ upstream: AnyPublisher<Action, Never>) -> AnyPublisher<DomainState, Never>`
- `Emission` type: `.state`, `.perform(work:)`, `.observe(publisher:)` returning `AnyPublisher`
- `DynamicState`: Wraps `CurrentValueSubject` for synchronous state access
- `Interact`: Uses `.feedback()` Combine operator for feedback loop
- Feedback loop: Uses `CurrentValueSubject`, `AnyCancellable`, and `sink` subscriptions

**Target AsyncStream Architecture**:
- `Interactor` protocol: `func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState>` with `@MainActor` isolation
- `Emission` type: `.state`, `.perform { state, send in ... }`, `.observe { state, send in ... }` using `DynamicState` and `Send` callback (both have identical signatures)
- `DynamicState`: Uses async accessor `{ @Sendable () async -> State }` for thread-safe state access
- `Interact`: Uses `Task`, `StateBox`, and direct AsyncStream yielding
- `Send` type: `@MainActor` callback for effect-to-state communication

## Desired End State

All core infrastructure types migrated to AsyncStream:
- `Interactor` protocol with `@MainActor` isolation
- `Send` type for effect callbacks
- `StateBox` for thread-safe state management
- `DynamicState` with async accessor
- `Emission` with Send callback pattern
- `Interact` primitive with Task-based feedback loop

## What We're NOT Doing

- Higher-order interactors (`Merge`, `MergeMany`, `Debounce`, `When`) - Phase 2
- Testing infrastructure (`TestClock`, `AsyncStreamRecorder`) - Phase 3
- Migrating example interactors - Phase 4
- ViewModel integration - Phase 5
- Cleanup and documentation - Phase 6

---

## Implementation Steps

### Step 1: Verify swift-async-algorithms Dependency

**File**: `Package.swift`

**Status**: Already present.

**Action**: No change needed.

---

### Step 2: Create Send Type

**File**: `Sources/UnoArchitecture/Internal/Send.swift` (NEW)

```swift
import Foundation

/// A callback for emitting state updates from effects.
///
/// `Send` is `@MainActor` isolated, ensuring all state mutations occur on the
/// main thread. When called from a non-isolated async context (like an effect
/// closure), Swift automatically handles the actor hop.
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

---

### Step 3: Create StateBox Type

**File**: `Sources/UnoArchitecture/Internal/StateBox.swift` (NEW)

```swift
import Foundation

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

---

### Step 4: Replace DynamicState

**File**: `Sources/UnoArchitecture/Domain/DynamicState.swift`

```swift
import Foundation

/// A type that provides **read-only** dynamic member lookup access to the current state
/// within an `observe` emission handler.
///
/// State access is asynchronous because it reads from actor-isolated storage,
/// ensuring thread-safe access to the latest value.
@dynamicMemberLookup
public struct DynamicState<State>: Sendable {
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
```

---

### Step 5: Replace Emission Type

**File**: `Sources/UnoArchitecture/Domain/Emission.swift`

```swift
import Foundation

/// A descriptor that tells an ``Interactor`` _how_ to emit domain state downstream.
public struct Emission<State: Sendable>: Sendable {
    public enum Kind: Sendable {
        /// Immediately forward state as-is.
        case state

        /// Execute an asynchronous unit of work and emit state via the `Send` callback.
        /// The closure receives `DynamicState` for reading fresh state and `Send` for emitting updates.
        case perform(work: @Sendable (DynamicState<State>, Send<State>) async -> Void)

        /// Observe a stream, emitting state for each element via the `Send` callback.
        /// The closure receives `DynamicState` for reading fresh state and `Send` for emitting updates.
        case observe(stream: @Sendable (DynamicState<State>, Send<State>) async -> Void)
    }

    let kind: Kind

    public static var state: Emission {
        Emission(kind: .state)
    }

    public static func perform(
        _ work: @escaping @Sendable (DynamicState<State>, Send<State>) async -> Void
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

---

### Step 6: Replace Interactor Protocol

**File**: `Sources/UnoArchitecture/Domain/Interactor.swift`

```swift
import AsyncAlgorithms
import Foundation

/// A type that transforms a stream of **actions** into a stream of **domain state**.
@MainActor
public protocol Interactor<DomainState, Action> {
    associatedtype DomainState: Sendable
    associatedtype Action
    associatedtype Body: Interactor

    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState>
}

extension Interactor where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
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

extension Interactor {
    public func eraseToAnyInteractor() -> AnyInteractor<DomainState, Action> {
        AnyInteractor(self)
    }
}
```

---

### Step 7: Replace Interact Primitive

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift`

```swift
import AsyncAlgorithms
import Foundation

/// A primitive used *inside* an ``Interactor``'s ``Interactor/body-swift.property`` for
/// handling incoming **actions** and emitting new **state** via an ``Emission``.
@MainActor
public struct Interact<State: Sendable, Action>: Interactor {
    public typealias Handler = @MainActor (inout State, Action) -> Emission<State>

    private let initialValue: State
    private let handler: Handler

    public init(initialValue: State, handler: @escaping Handler) {
        self.initialValue = initialValue
        self.handler = handler
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        let initialValue = self.initialValue
        let handler = self.handler

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                let stateBox = StateBox(initialValue)
                var effectTasks: [Task<Void, Never>] = []

                let send = Send<State> { newState in
                    stateBox.value = newState
                    continuation.yield(newState)
                }

                continuation.yield(stateBox.value)

                for await action in upstream {
                    var state = stateBox.value
                    let emission = handler(&state, action)
                    stateBox.value = state

                    switch emission.kind {
                    case .state:
                        continuation.yield(state)

                    case .perform(let work):
                        // DynamicState provides synchronized reads from the cooperative thread pool
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

                effectTasks.forEach { $0.cancel() }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
```

---

### Step 8: Update InteractorBuilder

**File**: `Sources/UnoArchitecture/Domain/Interactor/InteractorBuilder.swift`

Add `@MainActor` annotation and ensure `Sendable` constraint on State types where needed.

---

### Step 9: Update EmptyInteractor (Stub for Phase 2)

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/EmptyInteractor.swift`

```swift
import Foundation

@MainActor
public struct EmptyInteractor<State: Sendable, Action>: Interactor {
    public typealias DomainState = State
    public typealias Action = Action

    public init() {}

    public var body: some InteractorOf<Self> { self }

    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in upstream { }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
```

---

## Success Criteria

### Automated Verification

```bash
swift build
swift test
```

### Expected Build Errors (to be fixed in Phase 2)

After implementing Phase 1, the following files will have compilation errors:
1. `Debounce.swift` - Uses Combine's `debounce` operator
2. `When.swift` - Uses Combine publishers and PassthroughSubject
3. `CollectInteractors.swift` - Uses Combine publishers

These will be addressed in Phase 2: Higher-Order Interactors.

### Manual Verification

1. `Interact` handles `.state` emission
2. `Interact` handles `.perform` emission with async work
3. `Interact` handles `.observe` emission with external streams
4. Result builder compiles correctly

---

## Critical Files for Implementation

| File | Purpose |
|------|---------|
| `Sources/UnoArchitecture/Domain/Interactor.swift` | Core protocol with @MainActor and AsyncStream |
| `Sources/UnoArchitecture/Domain/Emission.swift` | Emission type with Send callback pattern |
| `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interact.swift` | Core feedback loop implementation |
| `Sources/UnoArchitecture/Internal/Send.swift` | New Send type for effect callbacks |
| `Sources/UnoArchitecture/Internal/StateBox.swift` | Thread-safe state container |
