# Phase 2: Higher-Order Interactors - Implementation Plan

## Overview

Phase 2 migrates all higher-order interactors from Combine to AsyncStream. This phase depends on Phase 1 (Core Infrastructure) which must be completed first.

## Current State Analysis

**Files to Migrate:**
1. `Sources/UnoArchitecture/Domain/Interactor/Interactors/Interactors.swift` - Namespace
2. `Sources/UnoArchitecture/Domain/Interactor/Interactors/Merge.swift` - Two-interactor merge
3. `Sources/UnoArchitecture/Domain/Interactor/Interactors/MergeMany.swift` - Array-based merge
4. `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift` - Time-based debouncing
5. `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift` - Child interactor embedding
6. `Sources/UnoArchitecture/Domain/Interactor/Interactors/ConditionalInteractor.swift` - If/else branching
7. `Sources/UnoArchitecture/Domain/Interactor/Interactors/CollectInteractors.swift` - Builder wrapper

**Already Migrated (Phase 1):**
- `Sources/UnoArchitecture/Domain/Interactor/Interactors/EmptyInteractor.swift` - No-op interactor

## Desired End State

All higher-order interactors use AsyncStream:
- `Merge` broadcasts actions to both interactors and appends state emissions
- `MergeMany` uses serialized processing for deterministic ordering
- `Debounce` uses `Clock` protocol instead of CombineSchedulers
- `When` uses `AsyncChannel` for back-pressure instead of `PassthroughSubject`
- `Conditional` switches between two interactor implementations
- `CollectInteractors` delegates to composed interactors

## What We're NOT Doing

- Core infrastructure (Phase 1)
- Testing infrastructure (Phase 3)
- Example migration (Phase 4)
- ViewModel integration (Phase 5)
- Cleanup (Phase 6)

---

## Implementation Steps

### Step 1: Conditional Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/ConditionalInteractor.swift`

```swift
extension Interactors {
    @MainActor
    public enum Conditional<First: Interactor, Second: Interactor<First.DomainState, First.Action>>: Interactor
    where First.DomainState: Sendable, First.Action: Sendable {
        case first(First)
        case second(Second)

        public var body: some Interactor<First.DomainState, First.Action> { self }

        public func interact(_ upstream: AsyncStream<First.Action>) -> AsyncStream<First.DomainState> {
            switch self {
            case .first(let first):
                return first.interact(upstream)
            case .second(let second):
                return second.interact(upstream)
            }
        }
    }
}
```

---

### Step 2: Merge Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Merge.swift`

Processes both child interactors sequentially (i0 then i1), preserving the original Combine `.append` behavior for deterministic ordering.

```swift
extension Interactors {
    @MainActor
    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor
    where I0.DomainState: Sendable, I0.Action: Sendable {
        private let i0: I0
        private let i1: I1

        public init(_ i0: I0, _ i1: I1) {
            self.i0 = i0
            self.i1 = i1
        }

        public var body: some Interactor<I0.DomainState, I0.Action> { self }

        public func interact(_ upstream: AsyncStream<I0.Action>) -> AsyncStream<I0.DomainState> {
            AsyncStream { continuation in
                let task = Task { @MainActor in
                    for await action in upstream {
                        // Process i0 first (sequential)
                        let (stream0, cont0) = AsyncStream<I0.Action>.makeStream()
                        cont0.yield(action)
                        cont0.finish()
                        for await state in i0.interact(stream0) {
                            continuation.yield(state)
                        }

                        // Then process i1 (sequential)
                        let (stream1, cont1) = AsyncStream<I0.Action>.makeStream()
                        cont1.yield(action)
                        cont1.finish()
                        for await state in i1.interact(stream1) {
                            continuation.yield(state)
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}
```

**Note**: Sequential processing preserves original Combine `.append` behavior - all states from i0 complete before i1 starts.

---

### Step 3: MergeMany Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/MergeMany.swift`

Processes all child interactors sequentially, preserving the original Combine `flatMap(maxPublishers: .max(1))` behavior for deterministic ordering.

```swift
extension Interactors {
    @MainActor
    public struct MergeMany<Element: Interactor>: Interactor
    where Element.DomainState: Sendable, Element.Action: Sendable {
        private let interactors: [Element]

        public init(interactors: [Element]) {
            self.interactors = interactors
        }

        public var body: some Interactor<Element.DomainState, Element.Action> { self }

        public func interact(_ upstream: AsyncStream<Element.Action>) -> AsyncStream<Element.DomainState> {
            AsyncStream { continuation in
                let task = Task { @MainActor in
                    for await action in upstream {
                        // Sequential processing - one interactor at a time
                        for interactor in interactors {
                            let (stream, cont) = AsyncStream<Element.Action>.makeStream()
                            cont.yield(action)
                            cont.finish()
                            for await state in interactor.interact(stream) {
                                continuation.yield(state)
                            }
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}
```

**Note**: Sequential processing preserves original Combine `flatMap(maxPublishers: .max(1))` behavior - interactors process in array order, one at a time.

---

### Step 4: Debounce Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift`

```swift
import AsyncAlgorithms

extension Interactors {
    @MainActor
    public struct Debounce<C: Clock, Child: Interactor>: Interactor
    where Child.DomainState: Sendable, Child.Action: Sendable, C: Sendable {
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
            AsyncStream { continuation in
                let task = Task { @MainActor in
                    let debouncedActions = upstream.debounce(for: duration, clock: clock)
                    let (childStream, childCont) = AsyncStream<Action>.makeStream()

                    let forwardTask = Task {
                        for await action in debouncedActions {
                            childCont.yield(action)
                        }
                        childCont.finish()
                    }

                    for await state in child.interact(childStream) {
                        continuation.yield(state)
                    }

                    forwardTask.cancel()
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}

extension Interactors.Debounce where C == ContinuousClock {
    @MainActor
    public init(for duration: Duration, child: () -> Child) {
        self.init(for: duration, clock: ContinuousClock(), child: child)
    }
}

public typealias DebounceInteractor<C: Clock, Child: Interactor> = Interactors.Debounce<C, Child>
```

---

### Step 5: When Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

This is the most complex migration due to back-pressure requirements.

```swift
import AsyncAlgorithms
import CasePaths

extension Interactor {
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

    public func when<ChildState, ChildAction, Child: Interactor>(
        stateIs toChildState: CaseKeyPath<DomainState, ChildState>,
        actionIs toChildAction: CaseKeyPath<Action, ChildAction>,
        stateAction toStateAction: CaseKeyPath<Action, ChildState>,
        @InteractorBuilder<ChildState, ChildAction> run child: () -> Child
    ) -> Interactors.When<Self, Child>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.When(
            parent: self,
            toChildState: .casePath(AnyCasePath(toChildState)),
            toChildAction: AnyCasePath(toChildAction),
            toStateAction: AnyCasePath(toStateAction),
            child: child()
        )
    }
}

extension Interactors {
    @MainActor
    public struct When<Parent: Interactor, Child: Interactor>: Interactor
    where Parent.DomainState: Sendable, Parent.Action: Sendable,
          Child.DomainState: Sendable, Child.Action: Sendable {
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

        public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState> {
            AsyncStream { continuation in
                let task = Task { @MainActor in
                    // AsyncChannel provides back-pressure
                    let childActionChannel = AsyncChannel<Child.Action>()
                    let (parentActionStream, parentCont) = AsyncStream<Action>.makeStream()

                    // Process child actions through child interactor
                    let childTask = Task { @MainActor in
                        for await childState in child.interact(childActionChannel.eraseToAsyncStream()) {
                            let stateAction = toStateAction.embed(childState)
                            parentCont.yield(stateAction)
                        }
                    }

                    // Route upstream actions
                    let routingTask = Task { @MainActor in
                        for await action in upstream {
                            if let childAction = toChildAction.extract(from: action) {
                                await childActionChannel.send(childAction)
                            } else {
                                parentCont.yield(action)
                            }
                        }
                        childActionChannel.finish()
                        parentCont.finish()
                    }

                    for await state in parent.interact(parentActionStream) {
                        continuation.yield(state)
                    }

                    childTask.cancel()
                    routingTask.cancel()
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}

extension AsyncChannel {
    func eraseToAsyncStream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                for await element in self {
                    continuation.yield(element)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
```

---

### Step 6: CollectInteractors

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/CollectInteractors.swift`

```swift
extension Interactors {
    @MainActor
    public struct CollectInteractors<State: Sendable, Action: Sendable, Interactors: Interactor>: Interactor
    where State == Interactors.DomainState, Action == Interactors.Action {
        private let interactors: Interactors

        public init(@InteractorBuilder<State, Action> _ build: () -> Interactors) {
            self.interactors = build()
        }

        public var body: some Interactor<State, Action> { self }

        public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
            interactors.interact(upstream)
        }
    }
}
```

---

## Implementation Order

1. **Conditional** - Simple delegation, no dependencies
2. **Merge** - Core composition pattern
3. **MergeMany** - Similar to Merge, array-based
4. **Debounce** - Requires Clock protocol from swift-async-algorithms
5. **When** - Most complex, requires AsyncChannel
6. **CollectInteractors** - Simple wrapper, depends on InteractorBuilder

---

## Success Criteria

### Automated Verification

```bash
swift build
swift test --filter MergeTests
swift test --filter MergeManyTests
swift test --filter DebounceTests
swift test --filter WhenTests
swift test --filter ConditionalTests
swift test --filter CollectInteractorsTests
```

### Behavioral Requirements

1. **Conditional**: Correct branch executes based on enum case
2. **Merge**: Actions broadcast to both interactors sequentially (i0 then i1); states arrive in deterministic order
3. **MergeMany**: Sequential processing; states from interactors arrive in array order (deterministic)
4. **Debounce**: Coalesces actions within window; TestClock controls time
5. **When**: Child actions routed correctly; back-pressure via AsyncChannel; state changes flow back as parent actions
6. **CollectInteractors**: Delegates to composed interactors built via InteractorBuilder

---

## Dependencies

**Required from Phase 1 (already implemented):**
- `Interactor` protocol with `AsyncStream<Action>` -> `AsyncStream<State>` and `@MainActor` isolation
- `DomainState: Sendable` and `Action: Sendable` constraints on Interactor protocol
- `Emission` type with Send callback pattern (`.state`, `.perform`, `.observe`)
- `Interact` primitive with StateBox, Send, and DynamicState
- `InteractorBuilder` result builder with `@MainActor` annotation
- `AnyInteractor` type eraser
- `Send<State>` type for effect-to-state communication
- `StateBox<State>` for thread-safe mutable state
- `DynamicState<State>` for async state reads in effects
- `EmptyInteractor` (already migrated in Phase 1)

**Required from Phase 3 (for testing):**
- `TestClock` for deterministic time control
- `AsyncStreamRecorder` for emission capture

**External Dependencies:**
- swift-async-algorithms (already in Package.swift) - provides `debounce`, `AsyncChannel`
- CasePaths (already in Package.swift) - provides `CaseKeyPath`, `AnyCasePath`

---

## Critical Files for Implementation

| File | Purpose | Complexity |
|------|---------|------------|
| `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift` | AsyncChannel for back-pressure, action routing | High |
| `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift` | Clock protocol integration, swift-async-algorithms | Medium |
| `Sources/UnoArchitecture/Domain/Interactor/Interactors/MergeMany.swift` | Sequential processing of interactor array | Low |
| `Sources/UnoArchitecture/Domain/Interactor/Interactors/Merge.swift` | Sequential processing of two interactors | Low |
| `Sources/UnoArchitecture/Domain/Interactor/Interactors/ConditionalInteractor.swift` | Simple delegation | Low |
| `Sources/UnoArchitecture/Domain/Interactor/Interactors/CollectInteractors.swift` | InteractorBuilder wrapper | Low |
