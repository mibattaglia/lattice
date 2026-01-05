# When Interactor Implementation Plan

## Overview

Implement the `When` higher-order interactor following TCA's `Scope` pattern. This allows embedding a child interactor that operates on a subset of parent state and actions, with automatic state synchronization via case paths.

## Current State Analysis

### Existing Code
- `When.swift` is completely commented out (old async stream pattern)
- `Interactors+WhenTests.swift` tests are also commented out
- Old design required `stateAction` parameter for state synchronization

### Key Discoveries
- `Emission.swift:188-220` has `.map` function for transforming actions
- TCA's `Scope.swift` shows clean pattern without `stateAction` parameter
- CasePath `embed`/`extract` handles state synchronization automatically

## Desired End State

After implementation:

1. `Interactors.When` provides a higher-order interactor for child state/action scoping
2. Two variants supported:
   - **keyPath** (struct state): `When(state: \.child, action: \.child) { ChildInteractor() }`
   - **casePath** (enum state): `When(state: \.loaded, action: \.loaded) { LoadedInteractor() }`
3. Modifier syntax available: `.when(state: \.child, action: \.child) { ... }`
4. No `stateAction` parameter needed
5. All tests pass

### Verification Commands

```bash
# All tests pass
swift test

# Build succeeds
swift build
```

## What We're NOT Doing

- Backwards compatibility with old `stateAction` API
- Runtime warnings for case path state mismatches (can add later if needed)
- `ifCaseLet` operator variant (can add later)

## Implementation Approach

Follow TCA's `Scope` pattern:
1. Extract child state via keyPath/casePath
2. Run child interactor
3. For casePath: embed child state back using `defer`
4. Map child emissions to parent action space

---

## Phase 1: When Interactor Implementation

### Overview

Implement the core `Interactors.When` struct with both keyPath and casePath support.

### Changes Required:

#### 1. When Interactor

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

**Changes**: Replace commented code with new implementation

```swift
import CasePaths
import Foundation

extension Interactors {
    /// Embeds a child interactor in a parent domain.
    ///
    /// `When` allows you to scope a parent domain to a child domain, running a child
    /// interactor on that subset. This enables modular feature composition by breaking
    /// large features into smaller, testable units.
    ///
    /// ## Usage with KeyPath (struct state)
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     Interactors.When(state: \.counter, action: \.counter) {
    ///         CounterInteractor()
    ///     }
    ///     Interact { state, action in
    ///         // Additional parent logic
    ///     }
    /// }
    /// ```
    ///
    /// ## Usage with CaseKeyPath (enum state)
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     Interactors.When(state: \.loaded, action: \.loaded) {
    ///         LoadedInteractor()
    ///     }
    /// }
    /// ```
    ///
    /// ## How It Works
    ///
    /// 1. Actions matching `toChildAction` are extracted and forwarded to the child
    /// 2. Child processes these actions and mutates its portion of state
    /// 3. For casePath state, child state is embedded back into parent state
    /// 4. Child emissions are mapped to parent action space
    /// 5. Non-matching actions pass through with `.none` emission
    public struct When<ParentState: Sendable, ParentAction: Sendable, Child: Interactor & Sendable>:
        Interactor, Sendable
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

        init(
            toChildState: StatePath,
            toChildAction: AnyCasePath<ParentAction, Child.Action>,
            child: Child
        ) {
            self.toChildState = toChildState
            self.toChildAction = toChildAction
            self.child = child
        }

        /// Creates a scoped interactor for struct state using a writable key path.
        ///
        /// - Parameters:
        ///   - toChildState: A writable key path from parent state to child state.
        ///   - toChildAction: A case key path from parent action to child actions.
        ///   - child: A closure that returns the child interactor.
        public init<ChildState, ChildAction>(
            state toChildState: WritableKeyPath<ParentState, ChildState>,
            action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) where ChildState == Child.DomainState, ChildAction == Child.Action {
            self.init(
                toChildState: .keyPath(toChildState),
                toChildAction: AnyCasePath(toChildAction),
                child: child()
            )
        }

        /// Creates a scoped interactor for enum state using a case key path.
        ///
        /// - Parameters:
        ///   - toChildState: A case key path from parent state to child state.
        ///   - toChildAction: A case key path from parent action to child actions.
        ///   - child: A closure that returns the child interactor.
        public init<ChildState, ChildAction>(
            state toChildState: CaseKeyPath<ParentState, ChildState>,
            action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) where ChildState == Child.DomainState, ChildAction == Child.Action {
            self.init(
                toChildState: .casePath(AnyCasePath(toChildState)),
                toChildAction: AnyCasePath(toChildAction),
                child: child()
            )
        }

        public var body: some Interactor<ParentState, ParentAction> { self }

        public func interact(state: inout ParentState, action: ParentAction) -> Emission<ParentAction> {
            guard let childAction = toChildAction.extract(from: action) else {
                return .none
            }

            switch toChildState {
            case .keyPath(let keyPath):
                let childEmission = child.interact(state: &state[keyPath: keyPath], action: childAction)
                return childEmission.map { toChildAction.embed($0) }

            case .casePath(let casePath):
                guard var childState = casePath.extract(from: state) else {
                    return .none
                }
                defer { state = casePath.embed(childState) }
                let childEmission = child.interact(state: &childState, action: childAction)
                return childEmission.map { toChildAction.embed($0) }
            }
        }
    }
}

/// Convenience alias for `Interactors.When`.
public typealias WhenInteractor<ParentState: Sendable, ParentAction: Sendable, Child: Interactor & Sendable> =
    Interactors.When<ParentState, ParentAction, Child>
where Child.DomainState: Sendable, Child.Action: Sendable
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`
- [ ] Type checking passes

#### Manual Verification:
- [ ] When struct compiles with both keyPath and casePath variants
- [ ] Documentation is accurate

---

## Phase 2: Interactor Extension Modifier

### Overview

Add `.when()` modifier syntax on `Interactor` for fluent API.

### Changes Required:

#### 1. When Modifier Extension

**File**: `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

**Changes**: Add extension at end of file

```swift
// MARK: - Interactor Modifier

extension Interactor where Self: Sendable {
    /// Scopes a child interactor to a subset of state and actions.
    ///
    /// Use `when` to embed a child interactor that operates on a portion of the parent's
    /// state and handles a subset of actions.
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     Interact { state, action in
    ///         // Parent logic
    ///     }
    ///     .when(state: \.child, action: \.child) {
    ///         ChildInteractor()
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - toChildState: A writable key path from parent state to child state.
    ///   - toChildAction: A case key path from parent action to child actions.
    ///   - child: A closure that returns the child interactor.
    /// - Returns: A combined interactor that handles both parent and child domains.
    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
        state toChildState: WritableKeyPath<DomainState, ChildState>,
        action toChildAction: CaseKeyPath<Action, ChildAction>,
        @InteractorBuilder<ChildState, ChildAction> child: () -> Child
    ) -> Interactors.Merge<Interactors.When<DomainState, Action, Child>, Self>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.Merge(
            Interactors.When(state: toChildState, action: toChildAction, child: child),
            self
        )
    }

    /// Scopes a child interactor to a subset of state and actions (enum state variant).
    ///
    /// Use `when` to embed a child interactor that operates on a portion of the parent's
    /// state and handles a subset of actions. This variant uses a case key path for
    /// enum-based state.
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     Interact { state, action in
    ///         // Parent logic
    ///     }
    ///     .when(state: \.loaded, action: \.loaded) {
    ///         LoadedInteractor()
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - toChildState: A case key path from parent state to child state.
    ///   - toChildAction: A case key path from parent action to child actions.
    ///   - child: A closure that returns the child interactor.
    /// - Returns: A combined interactor that handles both parent and child domains.
    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
        state toChildState: CaseKeyPath<DomainState, ChildState>,
        action toChildAction: CaseKeyPath<Action, ChildAction>,
        @InteractorBuilder<ChildState, ChildAction> child: () -> Child
    ) -> Interactors.Merge<Interactors.When<DomainState, Action, Child>, Self>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.Merge(
            Interactors.When(state: toChildState, action: toChildAction, child: child),
            self
        )
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] Build succeeds: `swift build`

#### Manual Verification:
- [ ] Modifier chains correctly with parent interactors
- [ ] Both keyPath and casePath variants work

---

## Phase 3: Update Tests

### Overview

Update `Interactors+WhenTests.swift` to use new API and uncomment tests.

### Changes Required:

#### 1. When Tests

**File**: `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+WhenTests.swift`

**Changes**: Rewrite tests for new sync API

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

@CasePathable
enum CounterAction: Sendable {
    case increment
    case decrement
}

// MARK: - Test Interactors

struct CounterInteractor: Interactor, Sendable {
    var body: some InteractorOf<Self> {
        Interact<CounterState, CounterAction> { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none
            case .decrement:
                state.count -= 1
                return .none
            }
        }
    }
}

// MARK: - Tests

@Suite
@MainActor
struct WhenTests {

    @Test
    func whenKeyPathBasicFunctionality() async throws {
        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let interactor = Interactors.When(state: \.counter, action: \.counter) {
            CounterInteractor()
        }

        // Send increment action
        let emission = interactor.interact(state: &state, action: .counter(.increment))

        // State should be updated
        #expect(state.counter.count == 1)
        #expect(state.otherProperty == "test")

        // Emission should be .none (CounterInteractor returns .none)
        switch emission.kind {
        case .none:
            break // Expected
        default:
            Issue.record("Expected .none emission")
        }
    }

    @Test
    func whenKeyPathIgnoresNonChildActions() async throws {
        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let interactor = Interactors.When(state: \.counter, action: \.counter) {
            CounterInteractor()
        }

        // Send non-child action
        let emission = interactor.interact(state: &state, action: .otherAction)

        // State should be unchanged
        #expect(state.counter.count == 0)

        // Emission should be .none (action not handled)
        switch emission.kind {
        case .none:
            break // Expected
        default:
            Issue.record("Expected .none emission")
        }
    }

    @Test
    func whenKeyPathMultipleActions() async throws {
        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let interactor = Interactors.When(state: \.counter, action: \.counter) {
            CounterInteractor()
        }

        _ = interactor.interact(state: &state, action: .counter(.increment))
        #expect(state.counter.count == 1)

        _ = interactor.interact(state: &state, action: .counter(.increment))
        #expect(state.counter.count == 2)

        _ = interactor.interact(state: &state, action: .counter(.decrement))
        #expect(state.counter.count == 1)
    }

    @Test
    func whenModifierCombinesWithParent() async throws {
        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let interactor = Interact<ParentState, ParentAction> { state, action in
            switch action {
            case .otherAction:
                state.otherProperty = "modified"
                return .none
            case .counter:
                return .none
            }
        }
        .when(state: \.counter, action: \.counter) {
            CounterInteractor()
        }

        // Child action handled by When
        _ = interactor.interact(state: &state, action: .counter(.increment))
        #expect(state.counter.count == 1)
        #expect(state.otherProperty == "test")

        // Parent action handled by parent
        _ = interactor.interact(state: &state, action: .otherAction)
        #expect(state.otherProperty == "modified")
    }

    @Test
    func whenChildEmissionMapsToParentAction() async throws {
        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        // Child interactor that emits an action
        let childInteractor = Interact<CounterState, CounterAction> { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .action(.decrement) // Emit follow-up action
            case .decrement:
                state.count -= 1
                return .none
            }
        }

        let interactor = Interactors.When(state: \.counter, action: \.counter) {
            childInteractor
        }

        let emission = interactor.interact(state: &state, action: .counter(.increment))

        // State should reflect increment
        #expect(state.counter.count == 1)

        // Emission should be mapped to parent action
        switch emission.kind {
        case .action(let action):
            #expect(action == .counter(.decrement))
        default:
            Issue.record("Expected .action emission")
        }
    }
}

// MARK: - Enum State Tests

@CasePathable
enum LoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded(CounterState)
}

@CasePathable
enum LoadingAction: Sendable {
    case startLoading
    case loaded(CounterAction)
}

@Suite
@MainActor
struct WhenCasePathTests {

    @Test
    func whenCasePathBasicFunctionality() async throws {
        var state = LoadingState.loaded(CounterState(count: 0))

        let interactor = Interactors.When(state: \.loaded, action: \.loaded) {
            CounterInteractor()
        }

        let emission = interactor.interact(state: &state, action: .loaded(.increment))

        // State should be updated
        if case .loaded(let counter) = state {
            #expect(counter.count == 1)
        } else {
            Issue.record("Expected .loaded state")
        }

        // Emission should be .none
        switch emission.kind {
        case .none:
            break
        default:
            Issue.record("Expected .none emission")
        }
    }

    @Test
    func whenCasePathIgnoresWhenStateDoesNotMatch() async throws {
        var state = LoadingState.idle

        let interactor = Interactors.When(state: \.loaded, action: \.loaded) {
            CounterInteractor()
        }

        let emission = interactor.interact(state: &state, action: .loaded(.increment))

        // State should remain idle
        #expect(state == .idle)

        // Emission should be .none
        switch emission.kind {
        case .none:
            break
        default:
            Issue.record("Expected .none emission")
        }
    }

    @Test
    func whenCasePathIgnoresNonChildActions() async throws {
        var state = LoadingState.loaded(CounterState(count: 0))

        let interactor = Interactors.When(state: \.loaded, action: \.loaded) {
            CounterInteractor()
        }

        let emission = interactor.interact(state: &state, action: .startLoading)

        // State should be unchanged
        if case .loaded(let counter) = state {
            #expect(counter.count == 0)
        } else {
            Issue.record("Expected .loaded state")
        }

        switch emission.kind {
        case .none:
            break
        default:
            Issue.record("Expected .none emission")
        }
    }
}
```

### Success Criteria:

#### Automated Verification:
- [ ] All tests pass: `swift test`
- [ ] No warnings or errors

#### Manual Verification:
- [ ] Tests cover keyPath and casePath variants
- [ ] Tests cover modifier syntax
- [ ] Tests cover child emission mapping

---

## Testing Strategy

### Unit Tests:
- KeyPath state scoping (struct parent state)
- CasePath state scoping (enum parent state)
- Non-matching actions ignored
- Child emissions mapped to parent actions
- Modifier syntax combines correctly

### Integration Tests:
- Multiple `.when()` modifiers chained
- Nested When interactors
- When combined with Merge/Debounce

### Manual Testing Steps:
1. Create feature with child interactor using keyPath
2. Verify child actions update parent state correctly
3. Create feature with enum state using casePath
4. Verify state transitions work correctly
5. Test effect emissions are properly mapped

## Performance Considerations

- No async overhead (synchronous processing)
- Single state extraction/embedding per action
- Emission mapping is lazy (closures not called until effect runs)

## Migration Notes

Consumer code changes from old API:

```swift
// Old API (removed)
.when(stateIs: \.counter, actionIs: \.counter, stateAction: \.counterStateChanged) {
    CounterInteractor()
}

// New API
.when(state: \.counter, action: \.counter) {
    CounterInteractor()
}
```

Key changes:
1. Parameter names: `stateIs` → `state`, `actionIs` → `action`
2. `stateAction` parameter removed (automatic via casePath)
3. Parent no longer needs to handle state synchronization actions

## References

- TCA Scope implementation: `/Users/michaelbattaglia/Documents/pointfree/swift-composable-architecture/Sources/ComposableArchitecture/Reducer/Reducers/Scope.swift`
- Emission.map: `Sources/UnoArchitecture/Domain/Emission.swift:188-220`
- Merge interactor: `Sources/UnoArchitecture/Domain/Interactor/Interactors/Merge.swift`
- Original plan: `thoughts/shared/plans/2025-01-03_sync_interactor_api.md`
