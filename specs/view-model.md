# ViewModel

`ViewModel` is Lattice's production bridge between SwiftUI and a `Feature`. It is a `@MainActor` reference type that owns runtime execution, publishes `viewState`, and gives views a single entry point for sending actions with `sendViewEvent(_:)`.

Key source files:

- [ViewModel.swift](../Sources/Lattice/Presentation/ViewModel/ViewModel.swift)
- [Feature.swift](../Sources/Lattice/Presentation/Feature/Feature.swift)
- [EventTask.swift](../Sources/Lattice/Presentation/ViewModel/EventTask.swift)
- [ViewModelBinding.swift](../Sources/Lattice/Presentation/ViewModel/ViewModelBinding.swift)
- [ViewModelTests.swift](../Tests/LatticeTests/PresentationTests/ViewModelTests.swift)

## Responsibilities

- Hold the authoritative production `DomainState`.
- Publish SwiftUI-facing `viewState`.
- Run the feature's interactor on the main actor.
- Reduce domain state into view state after relevant transitions.
- Start, track, and cancel effect work through root send scopes.
- Expose SwiftUI bindings that turn view-state writes into actions.

## Relationship To Feature

`ViewModel` is parameterized by `F: FeatureProtocol`, which gives it:

- A type-erased interactor.
- A type-erased view-state reducer.
- A closure for building the initial view state.
- A domain-state equality function used to decide whether sent actions need a fresh reduction.

`Feature(interactor:)` is the lightweight path for `DomainState == ViewState`. In that case the feature supplies an identity reducer automatically. See [Feature.swift](../Sources/Lattice/Presentation/Feature/Feature.swift).

## Initialization

The main initializer takes `initialDomainState` plus a `Feature`.

Initialization happens in two steps:

1. The feature builds an initial `ViewState` value through `makeInitialViewState`.
2. The reducer immediately runs once against the initial domain state before that value is stored as published `viewState`.

That second reduction matters because the initial factory is a construction hook, not a guarantee that the reducer has already fully projected the state.

## Published State

`viewState` is the only public state surface. Production `domainState` stays private to the view model.

The setter uses observation-aware behavior:

- If the new top-level `_$id` matches the existing `viewState`, the value is assigned directly.
- If the identity changes, the observation registrar wraps the mutation so SwiftUI can observe it correctly.

This works with `@ObservableState` and lets nested in-place mutations preserve identity where appropriate. See [ObservableState.swift](../Sources/Lattice/Observation/ObservableState.swift).

## Sending Actions

`sendViewEvent(_:)` is the only production event entry point.

When a view sends an action, the view model:

1. Creates a fresh root `SendScopeID`.
2. Buffers the sent action.
3. Drains the buffered-action queue.
4. Returns an `EventTask` tied to that root scope.

If the action produces no effect work, the returned `EventTask` has no underlying task and `hasEffects` is `false`.

## View-State Recalculation Rules

After every transition the view model commits the new domain state, then decides whether to run the reducer again.

- For `.sent` actions, the reducer runs only when `areStatesEqual(previousState, currentState)` is `false`.
- For `.emitted` actions, the reducer always runs.

That distinction is deliberate. Sent actions can skip redundant reductions when they are domain-state no-ops, while emitted actions always get a chance to refresh presentation state even if the domain-state equality function says the states match.

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

Both expose dynamic-member access into `viewState`, and `.sending(...)` turns writes back into actions.

Examples:

- Property binding: `$viewModel.name.sending(\.nameChanged)`
- Enum-case member binding: `$viewModel.loaded.query.sending(\.queryChanged)`

Case-path bindings have two variants:

- `sending(_:)` traps if the current `viewState` is not in the expected case.
- `sending(_:default:)` returns a fallback value and suppresses writes until the case matches again.

These APIs require `CasePaths` support for case-path-based action construction.

## What ViewModel Does Not Do

- It does not expose production `domainState` publicly.
- It does not own business logic; that stays in the interactor.
- It does not derive presentation values itself; that stays in the reducer.
- It does not model test-only buffering semantics; those live in `TestViewModel`.

## Related Specs

- [ViewModel Event Loop And Emission Handling](./view-model-event-loop-and-emission-handling.md)
- [ViewStateReducer](./view-state-reducer.md)
- [Interactors](./interactors.md)
- [Testing Infrastructure](./testing-infrastructure.md)
