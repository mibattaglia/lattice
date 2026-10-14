# Lattice Specs

Lattice is a Swift 6 library for building features with MVVM and unidirectional data flow. The runtime is organized around a small set of core responsibilities:

- `Interactor` owns synchronous state mutation and returns `Emission<Action>` values that describe follow-up work.
- `FeatureState` is a feature's one state: `@FeatureState` tracks it per member and generates the `ViewState` projection views read through, and `@Domain` hides members from it.
- `Feature` bundles an interactor and an optional state equality into one reusable unit.
- `ViewModel` runs the feature on the main actor, exposes the state through `State.ViewState`, and manages effect lifetimes through root send scopes and `EventTask`.
- Macros synthesize the boilerplate needed to declare interactors and feature state.
- Test infrastructure mirrors the runtime while making emitted actions explicit and step-wise.

The docs in this directory are source-driven descriptions of how those pieces fit together today.

## Contents

- [ViewModel](./view-model.md): lifecycle, initialization, feature wiring, reads through `State.ViewState`, the commit rules, and SwiftUI bindings. ✅ Implemented
- [ViewModel Event Loop And Emission Handling](./view-model-event-loop-and-emission-handling.md): buffered action draining, root send scopes, effect scheduling, append/merge behavior, and cancellation. ✅ Implemented
- [FeatureState](./feature-state.md): one state per feature, `@FeatureState` and `@Domain`, the generated `ViewState` projection, enum mirrors and payload kinds, observation guarantees, and limitations. ✅ Implemented
- [Interactors](./interactors.md): the core domain primitive, builder composition, scoped child features, emissions, and debouncing. ✅ Implemented
- [Macros](./macros.md): `@Interactor`, `@FeatureState`, `@Domain`, their helper macros, generated code, and diagnostics. ✅ Implemented
- [Testing Infrastructure](./testing-infrastructure.md): `TestViewModel`, state equality, `TestEventTask`, exhaustivity, `receive`, skip APIs, and time/debounce testing. ✅ Implemented

Design specs, with the reasoning behind the observation and composition behavior:

- [Identity-Preserving Assignment](./observable-state-identity-preserving-merge.md): content-equal assignments of `@FeatureState` members keep their registrars. ✅ Implemented
- [Fine-Grained Observation (Spec A)](./fine-grained-observation.md): the coarse key path fires only on a root identity change. ✅ Complete
- [Scoped View Composition (Spec B)](./scoped-view-composition.md): `scope(state:action:)` and `ScopedViewModel`. ✅ Implemented
- [Enum-Case Scoping (Spec C)](./enum-case-scoping.md): case scopes through the `@CasePathable` `ViewState` mirror. ✅ Implemented

## System Map

At a high level, the production path is:

1. A view sends an action through `ViewModel.sendViewEvent(_:)`.
2. The view model applies the action synchronously through the feature's interactor.
3. The interactor mutates a working copy of the state and returns an `Emission<Action>`; each member change notifies only that member's observers.
4. The view model commits the new state. A content-equal wholesale replacement is dropped, and only a new root identity fires the coarse key path that every reader registers; otherwise views re-render only for the members they read that changed.
5. The emission runtime schedules asynchronous work, re-enqueues emitted actions into the same root send scope, and tracks scope quiescence for `EventTask.finish()`.

The testing path uses the same action/execution machinery, but `TestViewModel` keeps emitted actions buffered until tests explicitly `receive(...)` or skip them.

## Primary Source Areas

- Runtime library: [Sources/Lattice](../Sources/Lattice)
- Macro plugin: [Sources/LatticeMacros](../Sources/LatticeMacros)
- Runtime and macro tests: [Tests](../Tests)
- Example usage: [ExampleProject](../ExampleProject)
