# Bootstrapping a New Lattice Feature

Use this guide when standing up a feature from scratch.

## Core contract

- `DomainState` is business logic state.
- `ViewState` is render instructions only.
- Interactors own side effects and external integrations.
- `ViewStateReducer` is synchronous and stateless.
- `Feature` bundles the interactor, reducer, initial-view-state behavior, and domain-state equality rules.
- Data flow is always one-way: view action -> interactor -> domain mutation -> reducer -> render.

## Modeling rules

- Put workflow state, raw values (`Date`, IDs), and domain-aligned external models in `DomainState`.
- Put display-ready values (strings, colors, booleans, composed presentation models) in `ViewState`.
- Do not push formatting, branching, or business rules into SwiftUI/UIKit views.

## Setup checklist

1. Define `DomainState` and `Action`.
2. Add `@Interactor<DomainState, Action>` to the feature interactor. Bare `@Interactor` is no longer valid.
3. Decide whether `ViewState` differs from `DomainState`.
4. If it differs, create an `@ObservableState` view state and an `@ViewStateReducer<DomainState, ViewState>`.
5. If the view state does not conform to `DefaultValueProvider`, implement `initialViewState(for:)` on the reducer.
6. Build `Feature(interactor:reducer:)`, or use `Feature(interactor:)` only when `DomainState == ViewState`.
7. Provide `areStatesEqual:` when `Equatable` is unavailable or when custom identity/version comparisons are the right redraw boundary.

## External clients and mapping

- Inject external clients into interactors (`APIClient`, `DBClient`, etc.).
- Perform async work in `.perform` / `.observe`, then emit actions.
- `.perform` returns `Action?`; return `nil` for cancelled or intentionally silent work.
- Map API/DB models at the interactor boundary into domain state.
- Keep codable models in domain state only when they are already domain-aligned and useful to business logic.
- Never require the view to interpret transport models for rendering.

## Lightweight option

For inert or server-driven/BFF-style UI, `Feature(interactor:)` is acceptable when `DomainState == ViewState`.
For non-trivial features, default to explicit `DomainState -> ViewState` layering.
