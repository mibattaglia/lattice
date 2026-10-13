# ViewModel

`ViewModel` is Lattice's production bridge between SwiftUI and a `Feature`. It is a `@MainActor` reference type that owns the feature's state and runtime execution, exposes that state to views through the `State.ViewState` projection, and gives views a single entry point for sending actions with `sendViewEvent(_:)`.

Key source files:

- [ViewModel.swift](../Sources/Lattice/Presentation/ViewModel/ViewModel.swift)
- [Feature.swift](../Sources/Lattice/Presentation/Feature/Feature.swift)
- [EventTask.swift](../Sources/Lattice/Presentation/ViewModel/EventTask.swift)
- [ViewModelBinding.swift](../Sources/Lattice/Presentation/ViewModel/ViewModelBinding.swift)
- [ScopedViewModel.swift](../Sources/Lattice/Presentation/ViewModel/ScopedViewModel.swift)
- [ViewModelTests.swift](../Tests/LatticeTests/PresentationTests/ViewModelTests.swift)
- [ViewModelObservationTests.swift](../Tests/LatticeTests/PresentationTests/ViewModelObservationTests.swift)

## Responsibilities

- Hold the authoritative production state, a `@FeatureState` value.
- Expose it to views through `State.ViewState`, so `@Domain` members stay hidden.
- Run the feature's interactor on the main actor.
- Commit each new state so that only the observers of changed members re-render.
- Start, track, and cancel effect work through root send scopes.
- Expose SwiftUI bindings that turn writes into actions, and scopes for child views.

## Relationship To Feature

`ViewModel` is parameterized by `F: FeatureProtocol`, which gives it:

- `F.Action` and `F.State` (a `FeatureState & Sendable` type).
- A type-erased interactor, `AnyInteractor<State, Action>`.
- An optional state equality, `areStatesEqual: ((State, State) -> Bool)?`.

`Feature(interactor:)` supplies `==` as the equality when the state is `Equatable` and `nil` otherwise. `Feature(interactor:areStatesEqual:)` takes a custom comparison. See [Feature.swift](../Sources/Lattice/Presentation/Feature/Feature.swift).

## Initialization

The initializer is `ViewModel(initialState:feature:)`. It stores the initial state as given; there is no separate view state to build.

```swift
let viewModel = ViewModel(
    initialState: CounterState(),
    feature: Feature(interactor: CounterInteractor())
)
```

## Reading State

Views read the state through `State.ViewState`, the projection `@FeatureState` generates:

- `viewModel.member` (`subscript(dynamicMember: KeyPath<State.ViewState, V>)`) is the fine-grained read. It registers the root and then each member it walks through on the state's own registrars, so `viewModel.badge.count` re-renders only when `count` changes or the state is replaced wholesale.
- `viewState: State.ViewState` is the whole projection. The value itself is coarse: it re-renders on a wholesale replacement or an enum case change. Members read off it stay fine-grained (the projection shares every registrar with the state), so `switch viewModel.viewState { case .loaded(let l): Text(l.title) }` re-renders on case changes and on `title` changes only.
- The raw `state` is internal. `TestViewModel`, `ScopedViewModel` and the bindings live in the same module and use it; views cannot.

A `@Domain` member is rejected at every read site with `'x' is unavailable: 'x' is @Domain state and is not visible to views`. See [FeatureState](./feature-state.md).

## Sending Actions

`sendViewEvent(_:)` is the only production event entry point.

When a view sends an action, the view model:

1. Creates a fresh root `SendScopeID`.
2. Buffers the sent action.
3. Drains the buffered-action queue.
4. Returns an `EventTask` tied to that root scope.

If the action produces no effect work, the returned `EventTask` has no underlying task and `hasEffects` is `false`.

## Commit Rules

For each drained action, the interactor mutates a working copy of the state. The copy shares every observation registrar with the stored state, so member notifications fire during `interact(state:action:)`, and an observer that re-reads the view model synchronously sees the previous committed value.

The view model then commits the result:

- If the new state has a different root `_$id` (a wholesale replacement) and `areStatesEqual` reports equal content, the current value is kept, so its registrar tree and every observer registered on it survive. Nothing changed for the view.
- Otherwise the new state is stored. If its root `_$id` changed, the view model fires its coarse `\.state` key path. Every reader re-renders, because member reads register the root too.

Sent and emitted actions commit the same way. See [ViewModel Event Loop And Emission Handling](./view-model-event-loop-and-emission-handling.md).

## EventTask

`sendViewEvent(_:)` returns an `EventTask`.

`EventTask` is scoped to the root send that started the work, not just the first generation of tasks.

- `finish()` waits for the full root scope to become quiescent, including child work started by emitted actions.
- `cancel()` cancels the currently tracked in-flight effects in that same scope.
- `hasEffects` tells you whether the send actually started any effect work.

This makes `EventTask` suitable for `.refreshable`, lifecycle-bound `.task`, and other places where the UI needs explicit completion or cancellation.

## SwiftUI Bindings

`ViewModel` supports action-sending bindings through [`ViewModelBinding.swift`](../Sources/Lattice/Presentation/ViewModel/ViewModelBinding.swift).

There are two entry points:

- `@Bindable var viewModel: ViewModel<F>`
- `Binding<ViewModel<F>>`

Both expose dynamic-member access rooted at `F.State.ViewState`, and `.sending(...)` turns writes back into actions. A `@Domain` member is rejected at the `$viewModel.member` site.

Examples:

- Property binding: `$viewModel.name.sending(\.nameChanged)`
- Nested member binding: `$viewModel.badge.label.sending(\.badge.labelChanged)`
- Enum-case member binding: `$viewModel.loaded.query.sending(\.queryChanged)`

Enum case bindings go through the state's `@CasePathable` `ViewState` mirror (`F.State.ViewState.AllCasePaths`), never the raw enum, so `@Domain` members of a `@FeatureState` payload stay hidden. They have two variants:

- `sending(_:)` traps if the current `viewState` is not in the expected case.
- `sending(_:default:)` returns a fallback value and suppresses writes until the case matches again.

These APIs require `CasePaths` support for case-path-based action construction.

## Scoping

`scope(state:action:)` projects the view model onto a child state for a child view, returning a stateless `ScopedViewModel`. Overloads cover a child, an optional child, a collection of identifiable children, an enum case (`scopeIfActive(state:action:)` and the trapping `scope(state:action:)`), a closure-mapped action, and a read-only child. See [Scoped View Composition](./scoped-view-composition.md) and [Enum-Case Scoping](./enum-case-scoping.md).

## What ViewModel Does Not Do

- It does not expose the raw state publicly.
- It does not own business logic; that stays in the interactor.
- It does not derive presentation values itself; computed members on the state do.
- It does not model test-only buffering semantics; those live in `TestViewModel`.

## Related Specs

- [ViewModel Event Loop And Emission Handling](./view-model-event-loop-and-emission-handling.md)
- [FeatureState](./feature-state.md)
- [Interactors](./interactors.md)
- [Testing Infrastructure](./testing-infrastructure.md)
