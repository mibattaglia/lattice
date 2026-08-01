# Lattice Specs

Lattice is a Swift library for building features with MVVM and unidirectional data flow. The
1.0 runtime lives in a single isolation domain and is organized around a small set of core
responsibilities:

- `Interactor` owns synchronous domain-state mutation via `interact(state:action:effects:)`
  and launches imperative effects with `effects.perform`; effects re-enter by mutating state
  directly (`effectState.modify`).
- One `@FeatureState` type per feature carries both the domain model (`@Domain` members) and
  the view contract (visible stored and computed members); the generated commit diff notifies
  exactly the visible members whose value or derived output changed.
- `ViewModel` is a thin main-actor host: views read visible members through the generated
  projection and send actions via `sendViewEvent(_:)`, which returns an `EventTask`.
- Macros (`@Interactor`, `@FeatureState`, `@Domain`) synthesize the conformance and
  projection boilerplate.
- Test infrastructure (`TestViewModel`) hosts the same core with a recording commit strategy
  and asserts every state change as a snapshot diff.

The current design is specified in [`sendable-removal/`](./sendable-removal/) — the plans in
that directory are the authoritative description of the 1.0 runtime.

## Contents

- [Sendable Removal & Imperative Effect Runtime](./sendable-removal/README.md): the 1.0
  design contract and its per-workstream plans. ✅ Implemented (plans 1–9)
- [Enum Case Scoping](./enum-case-scoping.md): scoping views onto enum-case payloads. ✅ Implemented
- [Scoped View Composition](./scoped-view-composition.md): `scope(state:action:)` and `ScopedViewModel`. ✅ Implemented
- [Macros](./macros.md): `@Interactor`, generated code, and diagnostics (with historical notes
  on the deleted macros). ✅ Implemented

### Historical (pre-1.0)

These describe the `Emission`/`ViewStateReducer`-era runtime deleted in the 1.0 rework and are
kept for design history only:

- [ViewModel](./view-model.md)
- [ViewModel Event Loop And Emission Handling](./view-model-event-loop-and-emission-handling.md)
- [ViewStateReducer](./view-state-reducer.md)
- [Interactors](./interactors.md)
- [Testing Infrastructure](./testing-infrastructure.md)
- [ObservableState Identity-Preserving Merge](./observable-state-identity-preserving-merge.md)
- [Fine-Grained Observation](./fine-grained-observation.md)

## System Map

At a high level, the production path is:

1. A view sends an action through `ViewModel.sendViewEvent(_:)`.
2. The view model runs the synchronous update phase in its isolation domain: the interactor
   mutates domain state in place and may launch effects with `effects.perform`.
3. Every mutation runs the commit funnel: scope-transition detection (cancelling effects whose
   `When` scope departed), then the generated projection diff, which notifies exactly the
   view-visible members whose value or derived output changed.
4. Effects start synchronously in-domain and re-enter later by mutating state directly with
   `effectState.modify` (or sending an action with `effectState.send`); each re-entry runs the
   same commit funnel.
5. `EventTask.finish()` awaits the effects launched directly by the send; `cancel()` cancels
   them.

The testing path hosts the same core with a recording commit strategy: `TestViewModel` asserts
the update-phase mutation on `send`, each effect `modify` commit with `expect`, and each
`effectState.send` re-entry with `receive`.

## Primary Source Areas

- Runtime library: [Sources/Lattice](../Sources/Lattice)
- Macro plugin: [Sources/LatticeMacros](../Sources/LatticeMacros)
- Runtime and macro tests: [Tests](../Tests)
- Example usage: [ExampleProject](../ExampleProject)
