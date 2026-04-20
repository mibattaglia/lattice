# Lattice Specs

Lattice is a Swift 6 library for building features with MVVM and unidirectional data flow. The runtime is organized around a small set of core responsibilities:

- `Interactor` owns synchronous domain-state mutation and returns `Emission<Action>` values that describe follow-up work.
- `ViewStateReducer` translates domain state into SwiftUI-facing render state.
- `Feature` bundles an interactor, reducer, initial view-state construction, and domain-state equality into one reusable unit.
- `ViewModel` runs the feature on the main actor, publishes `viewState`, and manages effect lifetimes through root send scopes and `EventTask`.
- Macros synthesize the boilerplate needed to declare interactors, reducers, and observable view state.
- Test infrastructure mirrors the runtime while making emitted actions explicit and step-wise.

The docs in this directory are source-driven descriptions of how those pieces fit together today.

## Contents

- [ViewModel](./view-model.md): lifecycle, initialization, feature wiring, `viewState` publication, and SwiftUI bindings. ✅ Implemented
- [ViewModel Event Loop And Emission Handling](./view-model-event-loop-and-emission-handling.md): buffered action draining, root send scopes, effect scheduling, append/merge behavior, and cancellation. ✅ Implemented
- [ViewStateReducer](./view-state-reducer.md): synchronous projection from domain state to render state, initial view-state rules, and `BuildViewState`. ✅ Implemented
- [Interactors](./interactors.md): the core domain primitive, builder composition, scoped child features, emissions, and debouncing. ✅ Implemented
- [Macros](./macros.md): `@Interactor`, `@ViewStateReducer`, `@ObservableState`, their helper macros, generated code, and diagnostics. ✅ Implemented
- [Testing Infrastructure](./testing-infrastructure.md): `TestViewModel`, `TestEventTask`, exhaustivity, `receive`, skip APIs, and time/debounce testing. ✅ Implemented

## System Map

At a high level, the production path is:

1. A view sends an action through `ViewModel.sendViewEvent(_:)`.
2. The view model applies the action synchronously through the feature's interactor.
3. The interactor mutates domain state and returns an `Emission<Action>`.
4. The view model reduces domain state into `viewState`.
5. The emission runtime schedules asynchronous work, re-enqueues emitted actions into the same root send scope, and tracks scope quiescence for `EventTask.finish()`.

The testing path uses the same action/execution machinery, but `TestViewModel` keeps emitted actions buffered until tests explicitly `receive(...)` or skip them.

## Primary Source Areas

- Runtime library: [Sources/Lattice](../Sources/Lattice)
- Macro plugin: [Sources/LatticeMacros](../Sources/LatticeMacros)
- Runtime and macro tests: [Tests](../Tests)
- Example usage: [ExampleProject](../ExampleProject)
