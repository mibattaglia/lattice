# Bootstrapping a New Lattice Feature

Use this guide when standing up a feature from scratch.

## Core contract

- One `@FeatureState` type per feature carries both the domain model and the view contract.
- `@Domain` members are business-logic state, visible only to the interactor and effects.
- Every other member — stored or computed — is view-visible; visible computed properties are derived view output.
- Interactors own side effects and external integrations, launched with `effects.perform`.
- Nothing conforms to `Sendable`: state, actions, interactors, and dependencies are plain types.
- Data flow is always one-way: view action -> interactor mutation/effect -> state commit -> projection diff -> render.

## Modeling rules

- Put workflow state, raw values (`Date`, IDs), and domain-aligned external models in `@Domain` members.
- Express display-ready values (strings, colors, booleans, composed presentation values) as visible members — usually computed properties deriving from `@Domain` storage.
- Do not push formatting, branching, or business rules into SwiftUI/UIKit views.

## Setup checklist

1. Define the state type and `Action` enum.
2. Annotate the state `@FeatureState`; mark interactor-only members `@Domain`.
3. Express derived view output as visible computed properties (they are diffed by output at commit).
4. Add `@Interactor<DomainState, Action>` to the feature interactor. Bare `@Interactor` is not valid.
5. Use the two-argument `Interact { state, action in }` for pure mutation; take the third `effects` parameter only where async work launches.
6. Build the view model with `ViewModel(initialState:interactor:)` (or bundle with `Feature(interactor:)` and `ViewModel(initialState:feature:)`).

## External clients and mapping

- Inject external clients into interactors (`APIClient`, `DBClient`, etc.) as plain protocols — no `Sendable` requirement.
- Perform async work with `effects.perform`; re-enter by mutating state with `try effectState.modify { … }` (no response actions).
- Map API/DB models at the interactor boundary into `@Domain` state.
- Keep codable models in domain state only when they are already domain-aligned and useful to business logic.
- Never require the view to interpret transport models for rendering — derive visible computed properties instead.

## Rows in lists

Store list elements as `@FeatureState` values in an `IdentifiedArrayOf` member; put each row's
rendering data in the element's visible computed properties. The commit diff is identity-keyed,
so one row's change re-renders only that row.
