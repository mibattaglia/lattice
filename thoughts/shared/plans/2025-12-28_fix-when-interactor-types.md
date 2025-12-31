# Fix When Interactor Composition

## Problem Statement

The `When` interactor cannot be composed with `Interact` in an `InteractorBuilder` body due to type mismatch:

```swift
// Current When types:
public typealias DomainState = ParentAction  // Outputs actions
public typealias Action = ParentAction

// Interact types:
public typealias DomainState = ParentState   // Outputs state
public typealias Action = ParentAction
```

The `InteractorBuilder` uses `Merge` which requires both interactors to have the same `DomainState` type. This causes:
```
static method 'buildExpression' requires the types 'SearchDomainState' and 'SearchEvent' be equivalent
```

## Architectural Context

**Why `When` outputs actions (not state):**

In UnoArchitecture, child interactors are isolated - they only know about `ChildState`/`ChildAction`. Unlike TCA where `Scope` receives `inout ParentState`, our child interactors cannot directly mutate parent state.

The action transformer pattern bridges this gap:
1. Child interactor emits `ChildState`
2. `When` wraps it in a state change action (`ParentAction`)
3. Parent's `Interact` receives that action and updates `ParentState`

This is the correct pattern for our architecture. The issue is **composition**, not the pattern itself.

---

## Solution 1: Modifier Pattern

### Concept

Instead of `When` being a sibling to `Interact`, it becomes a **modifier/wrapper** that wraps the parent interactor:

```swift
var body: some InteractorOf<Self> {
    Interact(initialValue: .none) { state, event in
        switch event {
        case .childStateChanged(let childState):
            state.child = childState
            return .state
        // ... other cases
        }
    }
    .when(stateIs: \.child, actionIs: \.child, stateAction: \.childStateChanged) {
        ChildInteractor()
    }
}
```

### How It Works

1. `Interact` is the base interactor (outputs `ParentState`)
2. `.when()` modifier wraps `Interact` and returns a new interactor that:
   - Intercepts the upstream action stream
   - Routes child actions to child interactor
   - Injects state change actions into the stream
   - Passes augmented action stream to wrapped `Interact`
   - Outputs `ParentState` (same as wrapped interactor)

### Data Flow

```
Actions ──┬──────────────────────────────┐
          │                              │
          ▼                              ▼
    ┌─────────────┐              ┌───────────────┐
    │ Child       │              │ When          │
    │ Interactor  │──ChildState─▶│ (Wrapper)     │
    └─────────────┘              │               │
                                 │ Injects       │
                                 │ stateAction   │
                                 └───────┬───────┘
                                         │
                    Augmented Actions    │
                    (original + state    │
                     change actions)     ▼
                                 ┌───────────────┐
                                 │   Interact    │
                                 │   (Wrapped)   │
                                 └───────┬───────┘
                                         │
                                         ▼
                                   ParentState
```

### Implementation Details

**Updated file:** `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

The existing `When` struct will be repurposed as the wrapper type, and new `.when()` extension methods will be added to `Interactor`.

```swift
extension Interactor {
    /// Embeds a child interactor that runs on a subset of this interactor's domain.
    ///
    /// The child interactor receives child actions extracted from parent actions,
    /// and its state changes are fed back as state change actions to this interactor.
    ///
    /// Use this modifier when the child state is a **struct property** of the parent state.
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///   Interact(initialValue: ParentState()) { state, action in
    ///     switch action {
    ///     case .childStateChanged(let childState):
    ///       state.child = childState
    ///       return .state
    ///     // ...
    ///     }
    ///   }
    ///   .when(stateIs: \.child, actionIs: \.child, stateAction: \.childStateChanged) {
    ///     ChildInteractor()
    ///   }
    /// }
    /// ```
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

    /// Embeds a child interactor that runs on a subset of this interactor's domain.
    ///
    /// Use this modifier when the child state is an **enum case** of the parent state.
    /// This pattern is useful for mutually-exclusive features (e.g., logged in vs. logged out).
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///   Interact(initialValue: .loggedOut(LoggedOut.State())) { state, action in
    ///     switch action {
    ///     case .loggedInStateChanged(let childState):
    ///       state = .loggedIn(childState)
    ///       return .state
    ///     // ...
    ///     }
    ///   }
    ///   .when(stateIs: \.loggedIn, actionIs: \.loggedIn, stateAction: \.loggedInStateChanged) {
    ///     LoggedInInteractor()
    ///   }
    /// }
    /// ```
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
    /// An ``Interactor`` that embeds a child interactor in a parent domain.
    ///
    /// ``When`` wraps a parent interactor and augments its action stream with child state
    /// changes. This allows child interactors to be composed with parent interactors while
    /// maintaining type safety.
    ///
    /// You typically create a ``When`` using the `.when()` modifier on an interactor:
    ///
    /// ```swift
    /// Interact(initialValue: ParentState()) { state, action in
    ///   // Handle actions including child state changes
    /// }
    /// .when(stateIs: \.child, actionIs: \.child, stateAction: \.childStateChanged) {
    ///   ChildInteractor()
    /// }
    /// ```
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

        public func interact(
            _ upstream: AnyPublisher<Action, Never>
        ) -> AnyPublisher<DomainState, Never> {
            let childActionSubject = PassthroughSubject<Child.Action, Never>()
            let stateHolder = CurrentValueSubject<Child.DomainState?, Never>(nil)

            let childCancellable = childActionSubject
                .interact(with: child)
                .sink { stateHolder.send($0) }

            // Augment action stream with state change actions
            let augmentedActions = upstream
                .flatMap { [toChildAction, toStateAction] action -> AnyPublisher<Action, Never> in
                    var outputs: [Action] = [action]

                    if let childAction = toChildAction.extract(from: action) {
                        childActionSubject.send(childAction)
                        if let state = stateHolder.value {
                            outputs.append(toStateAction.embed(state))
                        }
                    }

                    return outputs.publisher.eraseToAnyPublisher()
                }
                .handleEvents(receiveCancel: { childCancellable.cancel() })

            // Prepend initial child state action if available
            let initialAction: AnyPublisher<Action, Never>
            if let initialState = stateHolder.value {
                initialAction = Just(toStateAction.embed(initialState)).eraseToAnyPublisher()
            } else {
                initialAction = Empty().eraseToAnyPublisher()
            }

            // Pass augmented actions to parent interactor
            return initialAction
                .append(augmentedActions)
                .interact(with: parent)
                .eraseToAnyPublisher()
        }
    }
}
```

### Usage Example

```swift
@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor {
    let weatherService: WeatherService

    var body: some InteractorOf<Self> {
        Interact(initialValue: .none) { state, event in
            switch event {
            case .searchResultsChanged(let results):
                state = .results(results)
                return .state
            case .search:
                return .state
            case .locationTapped:
                return .state
            }
        }
        .when(
            stateIs: \.results,
            actionIs: \.search,
            stateAction: \.searchResultsChanged
        ) {
            SearchQueryInteractor(weatherService: weatherService)
        }
    }
}
```

### Pros
- Keeps `When` naming and semantics
- Clean fluent API
- Clear ownership: modifier wraps the interactor it modifies
- Type-safe composition (modifier preserves parent's types)
- No changes to `InteractorBuilder`
- Can chain multiple `.when()` calls

### Cons
- Order matters: base interactor first, then modifiers
- Breaking change to existing `When` API (now a modifier instead of standalone)

---

## Solution 3: Special Builder Handling

### Concept

Extend `InteractorBuilder` to recognize "action transformers" (interactors that output actions instead of state) and compose them specially with state-outputting interactors.

```swift
var body: some InteractorOf<Self> {
    When(stateIs: \.child, actionIs: \.child, stateAction: \.childStateChanged) {
        ChildInteractor()
    }

    Interact(initialValue: .none) { state, event in
        // Receives both original actions AND state change actions from When
    }
}
```

### How It Works

1. Define `ActionTransformer` protocol for action-to-action interactors
2. Add `buildExpression` overload that wraps action transformers
3. Add `buildPartialBlock` overload that composes action transformer + state interactor
4. Create `ActionTransformerMerge` that chains them: actions → transformer → augmented actions → state interactor

### Data Flow

```
Actions ──────────────────────────────────┐
          │                               │
          ▼                               │
    ┌─────────────┐                       │
    │    When     │◀──────────────────────┤
    │  (Action    │                       │
    │ Transformer)│                       │
    └──────┬──────┘                       │
           │                              │
           │ Augmented Actions            │
           │ (original + state changes)   │
           ▼                              │
    ┌──────────────────────────────────┐  │
    │  ActionTransformerMerge          │  │
    │  (Special Merge)                 │◀─┘
    │                                  │
    │  Feeds augmented actions to      │
    │  state interactor                │
    └──────────────┬───────────────────┘
                   │
                   ▼
            ┌─────────────┐
            │  Interact   │
            │  (State)    │
            └──────┬──────┘
                   │
                   ▼
              ParentState
```

### Implementation Details

**New protocol:** `ActionTransformer`

```swift
/// A specialized interactor that transforms actions to actions.
/// Used for routing child actions and emitting state change actions.
public protocol ActionTransformer<Action>: Interactor where DomainState == Action {
    // Marker protocol - DomainState must equal Action
}

// Make When conform
extension Interactors.When: ActionTransformer {}
```

**New interactor:** `ActionTransformerMerge`

```swift
extension Interactors {
    /// Composes an action transformer with a state-producing interactor.
    /// The transformer's action output feeds into the state interactor's input.
    public struct ActionTransformerMerge<
        Transformer: ActionTransformer,
        StateInteractor: Interactor
    >: Interactor
    where Transformer.Action == StateInteractor.Action {

        public typealias DomainState = StateInteractor.DomainState
        public typealias Action = Transformer.Action

        let transformer: Transformer
        let stateInteractor: StateInteractor

        public var body: some Interactor<DomainState, Action> { self }

        public func interact(
            _ upstream: AnyPublisher<Action, Never>
        ) -> AnyPublisher<DomainState, Never> {
            // Transform actions, then feed to state interactor
            let augmentedActions = upstream.interact(with: transformer)
            return augmentedActions.interact(with: stateInteractor)
        }
    }
}
```

**Builder extensions:**

```swift
extension InteractorBuilder {
    /// Accepts an action transformer and wraps it for composition.
    public static func buildExpression<T: ActionTransformer>(
        _ transformer: T
    ) -> ActionTransformerWrapper<T> where T.Action == Action {
        ActionTransformerWrapper(transformer)
    }

    /// Composes action transformer (accumulated) with state interactor (next).
    public static func buildPartialBlock<
        T: ActionTransformer,
        I: Interactor<State, Action>
    >(
        accumulated: ActionTransformerWrapper<T>,
        next: I
    ) -> Interactors.ActionTransformerMerge<T, I> where T.Action == Action {
        Interactors.ActionTransformerMerge(
            transformer: accumulated.transformer,
            stateInteractor: next
        )
    }

    /// Composes state interactor (accumulated) with action transformer (next).
    /// Transformer wraps the accumulated interactor.
    public static func buildPartialBlock<
        I: Interactor<State, Action>,
        T: ActionTransformer
    >(
        accumulated: I,
        next: ActionTransformerWrapper<T>
    ) -> Interactors.ActionTransformerMerge<T, I> where T.Action == Action {
        Interactors.ActionTransformerMerge(
            transformer: next.transformer,
            stateInteractor: accumulated
        )
    }
}

/// Wrapper to distinguish action transformers in the builder.
public struct ActionTransformerWrapper<T: ActionTransformer> {
    let transformer: T
}
```

### Usage Example

```swift
@Interactor<SearchDomainState, SearchEvent>
struct SearchInteractor {
    let weatherService: WeatherService

    var body: some InteractorOf<Self> {
        // Order doesn't matter - builder handles composition
        When(
            stateIs: \.results,
            actionIs: \.search,
            stateAction: \.searchResultsChanged
        ) {
            SearchQueryInteractor(weatherService: weatherService)
        }

        Interact(initialValue: .none) { state, event in
            switch event {
            case .searchResultsChanged(let results):
                state = .results(results)
                return .state
            case .search:
                return .state
            case .locationTapped:
                return .state
            }
        }
    }
}
```

### Pros
- Preserves current `When` API and mental model
- More closely matches TCA's `Scope` usage pattern
- Order-independent in body (builder handles it)
- Explicit about action transformer concept

### Cons
- More complex builder implementation
- New protocol and wrapper types
- Multiple builder overloads for different compositions
- Harder to reason about data flow
- Edge cases with multiple action transformers

---

## Comparison

| Aspect | Solution 1 (Modifier) | Solution 3 (Builder) |
|--------|----------------------|---------------------|
| API Style | `.when()` modifier | `When()` sibling |
| Complexity | Lower | Higher |
| Builder Changes | None | Significant |
| Type Safety | Strong | Strong |
| Order Dependency | Yes (modifier after base) | No (builder handles) |
| Mental Model | "Wrap and augment" | "Compose peers" |
| Naming | Keeps `When` semantics | Keeps `When` semantics |
| Implementation Effort | Medium | High |

## Recommendation

**Solution 1 (Modifier Pattern)** is recommended because:
1. Simpler implementation with no builder changes
2. Clear data flow (modifier wraps base interactor)
3. Composable (can chain multiple `.when()` calls)
4. Type-safe without new protocols
5. Easier to understand and debug
6. Keeps familiar `When` naming

---

## Implementation Plan (Solution 1)

### Phase 1: Update When Interactor

**File:** `Sources/UnoArchitecture/Domain/Interactor/Interactors/When.swift`

- [x] Replace existing `When` struct with new wrapper-based implementation
- [x] Change generic parameters from `<ParentState, ParentAction, Child>` to `<Parent, Child>`
- [x] Update `DomainState` typealias to `Parent.DomainState` (fixes the core issue)
- [x] Update `Action` typealias to `Parent.Action`
- [x] Add `parent` property to store wrapped interactor
- [x] Add `.when()` extension methods on `Interactor` protocol
- [x] Handle both struct key path and enum case path variants
- [x] Implement `interact()` with action augmentation
- [x] Remove top-level `When` typealias (breaking change)

### Phase 2: Update Tests

**File:** `Tests/UnoArchitectureTests/DomainTests/InteractorTests/InteractorsTests/Interactors+WhenTests.swift`

- [x] Update tests to use new `.when()` modifier API
- [x] Test struct key path composition
- [x] Test enum case path composition
- [x] Test child state changes trigger state change actions
- [x] Test non-child actions pass through unchanged
- [x] Test initial state emission
- [x] Test chaining multiple `.when()` calls

### Phase 3: Update Search Example

- [x] Update `SearchInteractor` to use `.when()` modifier
- [x] Verify build succeeds
- [x] Test functionality

### Phase 4: Clean Up

- [x] Update documentation in When.swift
- [x] Ensure all doc comments reflect new API

## Success Criteria

- [x] `.when()` modifier compiles and works with `Interact`
- [x] Search example builds and functions correctly
- [x] All tests pass
- [x] Documentation updated
