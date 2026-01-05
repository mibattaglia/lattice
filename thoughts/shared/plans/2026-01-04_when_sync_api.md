# When Interactor Sync API Implementation Plan

## Overview

Update the `When` interactor to use the synchronous interactor API, making it a first-class interactor usable in result builders while also keeping the modifier approach. Remove `toStateAction` since the sync API uses direct state mutation via `inout`.

## Current State Analysis

### Existing Implementation

The `When.swift` file is entirely commented out, containing the old async stream-based implementation:
- Used `AsyncChannel` for routing child actions
- Required `toStateAction` to embed child state changes back as parent actions
- Complex stream management with routing tasks

### Key Problems with Old Approach

1. **Indirection**: Child state changes had to be wrapped as actions and sent back to parent
2. **Complexity**: AsyncChannel routing, stream lifecycle management
3. **toStateAction requirement**: Verbose API requiring three case paths

### Solution

For scoping emissions, we capture parent state and create adapted DynamicState/Send:

```swift
return .perform { parentDynamic, parentSend in
    var parent = await parentDynamic.current  // Capture once

    let childDynamic = DynamicState<Child> {
        parent[keyPath: keyPath]
    }

    let childSend = Send<Child> { childState in
        parent[keyPath: keyPath] = childState
        parentSend(parent)
    }

    await work(childDynamic, childSend)
}
```

No changes needed to `DynamicState` or `Send`.

## Desired End State

After implementation:

1. `When<Child>` is a first-class interactor usable in `@InteractorBuilder`
2. `.when()` modifier available on any interactor for composition
3. `toStateAction` removed - no longer needed
4. Emission scoping via `Emission.scope(to:)` method
5. Full test coverage following TDD workflow

### Verification Commands

```bash
swift test
swift build
```

## What We're NOT Doing

- Backwards compatibility with old `toStateAction` API
- Changing DynamicState or Send infrastructure
- Supporting async-based When implementation

## Implementation Approach

Follow TDD workflow: Write failing tests first, then implement to make them pass.

---

## Phase 1: Write Failing Tests (RED)

### Overview

Write comprehensive tests for When behavior before implementation.

### Changes Required:

#### 1. Uncomment and Update Test File

**File**: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+WhenTests.swift`

```swift
import CasePaths
import Foundation
import Testing

@testable import UnoArchitecture

// MARK: - Test Domain Models

struct ParentState: Equatable, Sendable {
    var counter: CounterState
    var otherProperty: String
}

struct CounterState: Equatable, Sendable {
    var count: Int
}

@CasePathable
enum ParentAction: Sendable {
    case counter(CounterAction)
    case otherAction
}

enum CounterAction: Sendable {
    case increment
    case decrement
}

// MARK: - Test Interactors

struct CounterInteractor: Interactor, Sendable {
    typealias DomainState = CounterState
    typealias Action = CounterAction

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .state
            case .decrement:
                state.count -= 1
                return .state
            }
        }
    }
}

// MARK: - Tests

@Suite
@MainActor
struct WhenTests {

    // MARK: - First-Class When Tests

    @Test
    func whenFirstClassRoutesChildActions() async throws {
        let interactor = When(
            state: \ParentState.counter,
            action: \ParentAction.Cases.counter
        ) {
            CounterInteractor()
        }

        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let emission = interactor.interact(state: &state, action: .counter(.increment))

        #expect(state.counter.count == 1)
        #expect(state.otherProperty == "test")
        #expect(emission.kind == .state)
    }

    @Test
    func whenFirstClassIgnoresNonChildActions() async throws {
        let interactor = When(
            state: \ParentState.counter,
            action: \ParentAction.Cases.counter
        ) {
            CounterInteractor()
        }

        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let emission = interactor.interact(state: &state, action: .otherAction)

        #expect(state.counter.count == 0)  // Unchanged
        #expect(state.otherProperty == "test")  // Unchanged
    }

    // MARK: - Modifier When Tests

    @Test
    func whenModifierComposesWithParent() async throws {
        let parent = Interact<ParentState, ParentAction> { state, action in
            switch action {
            case .counter:
                return .state
            case .otherAction:
                state.otherProperty = "modified"
                return .state
            }
        }

        let interactor = parent
            .when(state: \.counter, action: \.counter) {
                CounterInteractor()
            }

        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        // Child action updates child state
        _ = interactor.interact(state: &state, action: .counter(.increment))
        #expect(state.counter.count == 1)

        // Parent action updates parent state
        _ = interactor.interact(state: &state, action: .otherAction)
        #expect(state.otherProperty == "modified")
    }

    @Test
    func whenModifierBothReceiveChildAction() async throws {
        var parentReceivedCounter = false

        let parent = Interact<ParentState, ParentAction> { state, action in
            if case .counter = action {
                parentReceivedCounter = true
            }
            return .state
        }

        let interactor = parent
            .when(state: \.counter, action: \.counter) {
                CounterInteractor()
            }

        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        _ = interactor.interact(state: &state, action: .counter(.increment))

        #expect(parentReceivedCounter == true)
        #expect(state.counter.count == 1)
    }

    // MARK: - Effect Tests

    @Test
    func whenChildEffectUpdatesParentState() async throws {
        struct AsyncCounterInteractor: Interactor, Sendable {
            var body: some InteractorOf<Self> {
                Interact<CounterState, CounterAction> { state, action in
                    switch action {
                    case .increment:
                        return .perform { dynamicState, send in
                            var current = await dynamicState.current
                            current.count += 10
                            send(current)
                        }
                    case .decrement:
                        state.count -= 1
                        return .state
                    }
                }
            }
        }

        let interactor = When(
            state: \ParentState.counter,
            action: \ParentAction.Cases.counter
        ) {
            AsyncCounterInteractor()
        }

        let harness = InteractorTestHarness(
            interactor: interactor,
            initialState: ParentState(counter: CounterState(count: 0), otherProperty: "test")
        )

        await harness.send(.counter(.increment))

        #expect(harness.state.counter.count == 10)
        #expect(harness.state.otherProperty == "test")
    }

    // MARK: - Multiple When Tests

    @Test
    func multipleWhenModifiers() async throws {
        struct TwoCounterState: Equatable, Sendable {
            var counter1: CounterState
            var counter2: CounterState
        }

        @CasePathable
        enum TwoCounterAction: Sendable {
            case counter1(CounterAction)
            case counter2(CounterAction)
        }

        let interactor = Interact<TwoCounterState, TwoCounterAction> { _, _ in .state }
            .when(state: \.counter1, action: \.counter1) {
                CounterInteractor()
            }
            .when(state: \.counter2, action: \.counter2) {
                CounterInteractor()
            }

        var state = TwoCounterState(
            counter1: CounterState(count: 0),
            counter2: CounterState(count: 100)
        )

        _ = interactor.interact(state: &state, action: .counter1(.increment))
        #expect(state.counter1.count == 1)
        #expect(state.counter2.count == 100)

        _ = interactor.interact(state: &state, action: .counter2(.decrement))
        #expect(state.counter1.count == 1)
        #expect(state.counter2.count == 99)
    }

    // MARK: - CasePath State Tests

    @Test
    func whenWithCasePathState() async throws {
        @CasePathable
        enum LoadingState: Equatable, Sendable {
            case loading
            case loaded(CounterState)
        }

        @CasePathable
        enum LoadingAction: Sendable {
            case startLoading
            case loaded(CounterAction)
        }

        let interactor = Interact<LoadingState, LoadingAction> { state, action in
            switch action {
            case .startLoading:
                state = .loading
                return .state
            case .loaded:
                return .state
            }
        }
        .when(state: \.loaded, action: \.loaded) {
            CounterInteractor()
        }

        // When in .loaded state, child actions work
        var state: LoadingState = .loaded(CounterState(count: 5))
        _ = interactor.interact(state: &state, action: .loaded(.increment))

        if case .loaded(let counter) = state {
            #expect(counter.count == 6)
        } else {
            Issue.record("Expected .loaded state")
        }

        // When NOT in .loaded state, child actions are no-op
        state = .loading
        _ = interactor.interact(state: &state, action: .loaded(.increment))

        #expect(state == .loading)
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Tests compile: `swift build --build-tests`
- [ ] Tests fail as expected (RED phase): `swift test --filter WhenTests`

---

## Phase 2: Add Emission Scoping

### Overview

Add `scope(to:)` methods to `Emission` for transforming child emissions to parent emissions using captured state.

### Changes Required:

#### 1. Add Scope Extension

**File**: `Sources/UnoArchitecture/Domain/Emission.swift`

**Changes**: Add at end of file

```swift
import CasePaths

// MARK: - Emission Scoping

extension Emission {
    /// Transforms this emission from child state to parent state using a key path.
    ///
    /// - Parameter keyPath: WritableKeyPath from parent state to child state.
    /// - Returns: An emission that operates on parent state.
    func scope<Parent>(
        to keyPath: WritableKeyPath<Parent, State>
    ) -> Emission<Parent> {
        switch kind {
        case .state:
            return .state

        case .perform(let work):
            return .perform { parentDynamic, parentSend in
                var parent = await parentDynamic.current

                let childDynamic = DynamicState<State>(getCurrentState: {
                    parent[keyPath: keyPath]
                })

                let childSend = Send<State> { childState in
                    parent[keyPath: keyPath] = childState
                    parentSend(parent)
                }

                await work(childDynamic, childSend)
            }

        case .observe(let stream):
            return .observe { parentDynamic, parentSend in
                var parent = await parentDynamic.current

                let childDynamic = DynamicState<State>(getCurrentState: {
                    parent[keyPath: keyPath]
                })

                let childSend = Send<State> { childState in
                    parent[keyPath: keyPath] = childState
                    parentSend(parent)
                }

                await stream(childDynamic, childSend)
            }

        case .merge(let emissions):
            return .merge(emissions.map { $0.scope(to: keyPath) })
        }
    }

    /// Transforms this emission from child state to parent state using a case path.
    ///
    /// - Parameter casePath: AnyCasePath from parent state to child state.
    /// - Returns: An emission that operates on parent state.
    func scope<Parent>(
        to casePath: AnyCasePath<Parent, State>
    ) -> Emission<Parent> {
        switch kind {
        case .state:
            return .state

        case .perform(let work):
            return .perform { parentDynamic, parentSend in
                var parent = await parentDynamic.current
                guard var childState = casePath.extract(from: parent) else { return }

                let childDynamic = DynamicState<State>(getCurrentState: {
                    childState
                })

                let childSend = Send<State> { newChildState in
                    childState = newChildState
                    parent = casePath.embed(newChildState)
                    parentSend(parent)
                }

                await work(childDynamic, childSend)
            }

        case .observe(let stream):
            return .observe { parentDynamic, parentSend in
                var parent = await parentDynamic.current
                guard var childState = casePath.extract(from: parent) else { return }

                let childDynamic = DynamicState<State>(getCurrentState: {
                    childState
                })

                let childSend = Send<State> { newChildState in
                    childState = newChildState
                    parent = casePath.embed(newChildState)
                    parentSend(parent)
                }

                await stream(childDynamic, childSend)
            }

        case .merge(let emissions):
            return .merge(emissions.map { $0.scope(to: casePath) })
        }
    }
}
```

#### 2. Make DynamicState Init Internal

**File**: `Sources/UnoArchitecture/Domain/DynamicState.swift`

**Changes**: Change init from private/internal to package-accessible if needed

```swift
init(getCurrentState: @escaping @Sendable () async -> State) {
    self.getCurrentState = getCurrentState
}
```

#### 3. Make Send Init Internal

**File**: `Sources/UnoArchitecture/Internal/Send.swift`

**Changes**: Ensure init is accessible for creating scoped Send

```swift
init(_ yield: @escaping @MainActor (State) -> Void) {
    self.yield = yield
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`

---

## Phase 3: Implement When Interactor

### Overview

Implement `When` as a first-class interactor.

### Changes Required:

#### 1. Rewrite When.swift

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

```swift
import CasePaths
import Foundation

extension Interactors {
    /// An interactor that scopes a child interactor to a subset of parent state and actions.
    ///
    /// `When` enables modular feature composition by routing specific actions to a child
    /// interactor that operates on a portion of the parent state.
    ///
    /// ## Usage as First-Class Interactor
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     When(state: \.counter, action: \.counter) {
    ///         CounterInteractor()
    ///     }
    /// }
    /// ```
    ///
    /// ## How It Works
    ///
    /// 1. Actions matching the action case path are extracted and forwarded to the child
    /// 2. The child processes these actions, mutating child state directly
    /// 3. Child state changes are written back to parent state
    /// 4. Actions not matching are ignored (return `.state`)
    public struct When<
        ParentState: Sendable,
        ParentAction: Sendable,
        Child: Interactor & Sendable
    >: Interactor, Sendable
    where Child.DomainState: Sendable, Child.Action: Sendable {
        public typealias DomainState = ParentState
        public typealias Action = ParentAction

        enum StatePath: @unchecked Sendable {
            case keyPath(WritableKeyPath<ParentState, Child.DomainState>)
            case casePath(AnyCasePath<ParentState, Child.DomainState>)
        }

        private let toChildState: StatePath
        private let toChildAction: AnyCasePath<ParentAction, Child.Action>
        private let child: Child

        /// Creates a When interactor with key path state access.
        public init<ChildAction>(
            state toChildState: WritableKeyPath<ParentState, Child.DomainState>,
            action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
            @InteractorBuilder<Child.DomainState, Child.Action> child: () -> Child
        ) where Child.Action == ChildAction {
            self.toChildState = .keyPath(toChildState)
            self.toChildAction = AnyCasePath(toChildAction)
            self.child = child()
        }

        /// Creates a When interactor with case path state access.
        public init<ChildAction>(
            state toChildState: CaseKeyPath<ParentState, Child.DomainState>,
            action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
            @InteractorBuilder<Child.DomainState, Child.Action> child: () -> Child
        ) where Child.Action == ChildAction {
            self.toChildState = .casePath(AnyCasePath(toChildState))
            self.toChildAction = AnyCasePath(toChildAction)
            self.child = child()
        }

        public var body: some Interactor<ParentState, ParentAction> { self }

        public func interact(state: inout ParentState, action: ParentAction) -> Emission<ParentState> {
            guard let childAction = toChildAction.extract(from: action) else {
                return .state
            }

            switch toChildState {
            case .keyPath(let keyPath):
                var childState = state[keyPath: keyPath]
                let childEmission = child.interact(state: &childState, action: childAction)
                state[keyPath: keyPath] = childState
                return childEmission.scope(to: keyPath)

            case .casePath(let casePath):
                guard var childState = casePath.extract(from: state) else {
                    return .state
                }
                let childEmission = child.interact(state: &childState, action: childAction)
                state = casePath.embed(childState)
                return childEmission.scope(to: casePath)
            }
        }
    }
}

/// Convenience typealias for `Interactors.When`.
public typealias WhenInteractor = Interactors.When
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`
- [ ] First-class When tests pass: `swift test --filter "whenFirstClass"`

---

## Phase 4: Implement When Modifier

### Overview

Add `.when()` modifier extension on `Interactor`.

### Changes Required:

#### 1. Add Modifier Extension

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

**Changes**: Add at end of file

```swift
// MARK: - When Modifier

extension Interactor where Self: Sendable {
    /// Composes this interactor with a child interactor scoped to a subset of state and actions.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// ParentInteractor()
    ///     .when(state: \.counter, action: \.counter) {
    ///         CounterInteractor()
    ///     }
    /// ```
    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
        state toChildState: WritableKeyPath<DomainState, ChildState>,
        action toChildAction: CaseKeyPath<Action, ChildAction>,
        @InteractorBuilder<ChildState, ChildAction> child: () -> Child
    ) -> Interactors.Merge<Self, Interactors.When<DomainState, Action, Child>>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.Merge(
            self,
            Interactors.When(state: toChildState, action: toChildAction, child: child)
        )
    }

    /// Composes this interactor with a child interactor scoped to enum state.
    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
        state toChildState: CaseKeyPath<DomainState, ChildState>,
        action toChildAction: CaseKeyPath<Action, ChildAction>,
        @InteractorBuilder<ChildState, ChildAction> child: () -> Child
    ) -> Interactors.Merge<Self, Interactors.When<DomainState, Action, Child>>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.Merge(
            self,
            Interactors.When(state: toChildState, action: toChildAction, child: child)
        )
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`
- [ ] All When tests pass: `swift test --filter WhenTests`

---

## Phase 5: Final Verification (GREEN)

### Overview

Run all tests and verify everything passes.

### Success Criteria:

#### Automated Verification:
- [ ] All tests pass: `swift test`
- [ ] Build succeeds: `swift build`

#### Manual Verification:
- [ ] When works as first-class interactor in result builder
- [ ] When modifier composes correctly with parent
- [ ] Child effects update parent state correctly
- [ ] CasePath scoping returns no-op when state not in expected case

---

## Testing Strategy

### Unit Tests:
- First-class When with keyPath state
- First-class When with casePath state
- When modifier with keyPath state
- When modifier with casePath state
- Child effects updating parent state
- Multiple When modifiers chained
- Non-child actions ignored by first-class When
- Non-child actions handled by parent in modifier

---

## References

- Sync interactor API plan: `thoughts/shared/plans/2025-01-03_sync_interactor_api.md`
- TCA Scope implementation: Reference for emission scoping pattern
- Current Debounce: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Debounce.swift`
