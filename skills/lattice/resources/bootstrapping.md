# Bootstrapping a New Lattice Feature

Use this guide when standing up a feature from scratch.

## Core contract

- A feature has one `@FeatureState` state. The interactor, with the effects it performs, is its only mutator.
- Views read the state through its generated `ViewState` projection, which omits `@Domain` members.
- Interactors own side effects and external integrations: `effects.perform` queues an effect, and the effect delivers its result with `effects.modify`.
- `Feature` bundles the interactor with the state equality (`areStatesEqual`).
- Nothing is `Sendable`: state, actions, interactors, dependencies and effect closures are plain types that run on the shell's isolation.
- Data flow is always one-way: view action -> interactor mutation and effects -> state commit -> re-render of the views that read a changed member.

## Modeling rules

- Mark workflow state, raw values (`Date`, IDs), and domain-aligned external models `@Domain`.
- Expose display-ready values (strings, colors, booleans, composed presentation models) as visible members, usually computed from the `@Domain` ones.
- Do not push formatting, branching, or business rules into SwiftUI/UIKit views.

## Setup checklist

1. Define the `@FeatureState` state and the `Action` enum. Import `Foundation` (or `SwiftUI`, or `Observation`) in the state's file.
2. Add `@Interactor<State, Action>` to the feature interactor, as its first attribute. Bare `@Interactor` is not valid.
3. Add computed members for what views render, and mark members views must not read `@Domain`.
4. Model child features as nested `@FeatureState` members or enum-case payloads, so views can scope into them.
5. Build `Feature(interactor:)`; it compares states with `==` when the state is `Equatable`.
6. Provide `Feature(interactor:areStatesEqual:)` when `Equatable` is unavailable or when custom identity/version comparisons are the right redraw boundary.
7. Create the view model with `ViewModel(initialState:feature:)`.
8. Declare each `@FeatureState` enum in its own file, with no other macro-annotated declaration (a Swift 6.4 compiler-crash workaround; see the main skill).
9. Test the feature with `TestModel` (see the `lattice-testing` skill).

## External clients and mapping

- Inject external clients into interactors (`APIClient`, `DBClient`, etc.) as plain protocols, classes or closures, with no `Sendable` requirement.
- Mark their async methods `nonisolated(nonsending)`, unless your module enables `NonisolatedNonsendingByDefault`, so that effects call them on the shell's isolation.
- Inject clocks as a generic parameter (`struct FooInteractor<C: Clock>`), with an `extension FooInteractor where C == ContinuousClock` initializer for the app.
- Perform async work in `effects.perform { … }` and write the result with `try effects.modify { … }`. There are no response actions.
- Catch the errors you expect and turn them into state; check `Task.checkCancellation()` before writing an error or a result a newer action made stale.
- Map API/DB models at the interactor boundary into the state.
- Keep codable models in the state (as `@Domain` members) only when they are already domain-aligned and useful to business logic.
- Never require the view to interpret transport models for rendering.

## Lightweight option

For inert or server-driven/BFF-style UI, leave every member visible: the state already is the render model.
For non-trivial features, keep raw data `@Domain` and expose computed presentation members.
