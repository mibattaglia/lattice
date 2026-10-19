# Lattice Specs

Lattice is a Swift 6 library for building features with MVVM and unidirectional data flow. The runtime is organized around a small set of core responsibilities:

- `Interactor` owns synchronous state mutation and queues asynchronous work through an `Effects` handle. Effects deliver their results by modifying state.
- `FeatureState` is a feature's one state: `@FeatureState` tracks it per member and generates the `ViewState` projection views read through, and `@Domain` hides members from it.
- `Feature` bundles an interactor and an optional state equality into one reusable unit.
- A nonisolated `Core` runs the feature: it holds the state, handles actions, and starts and cancels effects, only ever on the isolation of the shell that hosts it.
- `ViewModel` hosts the core on the main actor and exposes the state to SwiftUI through `State.ViewState`; `ActorModel` hosts it on an actor of its own.
- Macros synthesize the boilerplate needed to declare interactors and feature state.
- `TestModel` and `TestViewModel` run the same core and record every commit made outside the action under test, until the test asserts it.

The docs in this directory are source-driven descriptions of how those pieces fit together today.

## Contents

- [ViewModel](./view-model.md): lifecycle, feature wiring, reads through `State.ViewState`, sending actions, the commit rules, teardown, SwiftUI bindings, and `ActorModel`. ✅ Implemented
- [Effects And Isolation](./effects-and-isolation.md): the nonisolated core and its shells, how `send` handles an action, the `Effects` handle, auto-cancel and `@EffectID`, the task `send` returns, teardown, thrown errors, and the concurrency settings. ✅ Implemented
- [FeatureState](./feature-state.md): one state per feature, `@FeatureState` and `@Domain`, the generated `ViewState` projection, enum mirrors and payload kinds, observation guarantees, and limitations. ✅ Implemented
- [Interactors](./interactors.md): the core domain primitive, builder composition, scoped child features, debouncing, and the patterns for writing effects. ✅ Implemented
- [Macros](./macros.md): `@Interactor`, `@FeatureState`, `@Domain`, their helper macros, generated code, and diagnostics. ✅ Implemented
- [Testing Infrastructure](./testing-infrastructure.md): `TestModel` and `TestViewModel`, `send`/`receive`/`expect`/`finish`, folding and exhaustivity, waiting, and testing with clocks. ✅ Implemented

Design specs, with the reasoning behind the observation and composition behavior:

- [Identity-Preserving Assignment](./observable-state-identity-preserving-merge.md): content-equal assignments of `@FeatureState` members keep their registrars. ✅ Implemented
- [Fine-Grained Observation (Spec A)](./fine-grained-observation.md): the coarse key path fires only on a root identity change. ✅ Complete
- [Scoped View Composition (Spec B)](./scoped-view-composition.md): `scope(state:action:)` and `ScopedViewModel`. ✅ Implemented
- [Enum-Case Scoping (Spec C)](./enum-case-scoping.md): case scopes through the `@CasePathable` `ViewState` mirror. ✅ Implemented

## System Map

At a high level, the production path is:

1. A view sends an action through `ViewModel.sendViewEvent(_:)`, which hands it to the view model's `Core` on the main actor.
2. The core runs the interactor on a working copy of the state. Each member change notifies only that member's observers, and every effect the interactor performs is only queued.
3. The core commits the working copy. A content-equal wholesale replacement is dropped, and only a new root identity fires the coarse key path that every reader registers; otherwise views re-render only for the members they read that changed. Then it cancels the anonymous effects previously started for the same action case, at the root and at each child case a `When` routes the action into; effects with an `@EffectID` are never auto-cancelled.
4. The core starts the queued effects in order on the main actor. Each runs until its first suspension before `sendViewEvent(_:)` returns, which hands back the task for those effects.
5. Effects resume on the main actor after every suspension. They deliver results with `effects.modify`, which commits by the same rules, and send actions only to start effects, run interactor logic or cancel by action case.

`ActorModel` runs the same path on its own executor. The testing path runs it under `TestModel` or `TestViewModel`, which record every commit made outside the action under test, whether an action an effect sent or a modification an effect made, until the test describes it with `receive` or `expect`.

## Primary Source Areas

- Runtime library: [Sources/Lattice](../Sources/Lattice)
- Macro plugin: [Sources/LatticeMacros](../Sources/LatticeMacros)
- Runtime and macro tests: [Tests](../Tests)
- Example usage: [ExampleProject](../ExampleProject)
