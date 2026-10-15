---
name: lattice
description: Build Swift application features using Lattice interactors, effects, features, view models, and @FeatureState state.
license: MIT
metadata:
  short-description: Build features with Lattice.
---

# Lattice Architecture

## Goal

Build Swift features using Lattice's Interactor + Feature + ViewModel architecture over one `@FeatureState` state per feature.
For new feature setup, use the bootstrap checklist in `resources/bootstrapping.md`.

## State modeling rules

- A feature has one `@FeatureState` state, and its interactor, with the effects it performs, is the only code that mutates it.
- Views read the state through the generated `State.ViewState` projection. Visible members are render instructions; derive display values as computed members on the state.
- Mark business-logic members (raw values, workflow flags, domain-aligned external models) `@Domain`. They stay observation-tracked, so computed members that read them re-render, but views, scopes and bindings cannot read them.
- Interactors own side effects and external data access via dependencies, from their effects.
- Nothing in the feature layer has to be declared `Sendable`: state, actions, interactors, dependencies and effect closures are plain types. The feature runs on its shell's isolation, the main actor under `ViewModel`.
- Keep raw formatting concerns out of views.

## Quick start

1. Add the `lattice` package (`https://github.com/mibattaglia/lattice`) and depend on `.product(name: "Lattice", package: "lattice")` (Swift 6.2 tools or later).
2. Add the `Lattice` product to your target's dependencies.
3. `import Lattice` as needed. A file that declares a `@FeatureState` type also needs `Observation` in scope (`import Foundation` or `import SwiftUI` provides it).
4. `@Interactor<State, Action>` requires explicit generic arguments.

## Build a basic feature

```swift
import Foundation
import Lattice

@FeatureState
struct CounterState: Equatable {
    @Domain var count = 0
    var countText: String { String(count) }
}

enum CounterAction {
    case decrementButtonTapped
    case incrementButtonTapped
}

@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .decrementButtonTapped:
                state.count -= 1
            case .incrementButtonTapped:
                state.count += 1
            }
        }
    }
}
```

- Do name actions after user intent (`incrementButtonTapped`), not the state change.
- Do keep raw values `@Domain` and expose display values as computed members; there is no separate view-state type or reducer.
- `Interact { state, action, effects in … }` handles an action synchronously and returns nothing. When the handler performs no effects, drop the `effects` parameter: `Interact { state, action in … }`.
- Do make `Action` an enum: automatic cancellation keys on its case.

## Connect to SwiftUI

```swift
import Lattice
import SwiftUI

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialState: CounterState(),
        feature: Feature(interactor: CounterInteractor())
    )

    var body: some View {
        HStack {
            Button("-") { viewModel.sendViewEvent(.decrementButtonTapped) }
            Text(viewModel.countText)
            Button("+") { viewModel.sendViewEvent(.incrementButtonTapped) }
        }
    }
}
```

- Do keep view methods thin; move multi-line logic to private methods named after user actions.
- Do read members (`viewModel.countText`): each read is observed on its own. `viewModel.viewState` is the coarse read of the whole projection, for a `switch` over an enum state.
- Reading a `@Domain` member from a view does not compile: `'count' is unavailable: 'count' is @Domain state and is not visible to views`.
- `sendViewEvent(_:)` is synchronous and returns a discardable `Task<Void, Never>?` for exactly the effects that send started (`nil` when it started none). Await it where the effect ends by itself (`.refreshable { await viewModel.sendViewEvent(.refresh)?.value }`); from `.task`, forward cancellation to it (see the `lattice-modern-swiftui` skill). Cancelling it cancels those effects.
- `Feature(interactor:)` compares states with `==` when the state is `Equatable`. Pass `areStatesEqual:` when the state is not `Equatable` or when a version/identity comparison is the right boundary.
- Don't push formatting (`Date` to text, enum display labels, color decisions) into SwiftUI views.

## Async work

Queue effects with `effects.perform` during `interact`. An effect delivers its result with `effects.modify`; there is no response action to send and handle. Here `SearchState` has `query` and `results` members:

```swift
@Interactor<SearchState, SearchAction>
struct SearchInteractor {
    let searchClient: SearchClient

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .queryChanged(let query):
                state.query = query
                effects.perform {
                    let results: [String]
                    do {
                        results = try await searchClient.search(query)
                    } catch {
                        results = []
                    }
                    // A newer query cancelled this search while it ran: its results are stale. A
                    // cancelled effect's modification is still committed, so check first.
                    try Task.checkCancellation()
                    try effects.modify { $0.results = results }
                }
            }
        }
    }
}

protocol SearchClient {
    nonisolated(nonsending) func search(_ query: String) async throws -> [String]
}
```

- `effects.perform { … }` is legal only during `interact`. It is `noasync`, so inside an effect it does not compile; from a synchronous closure inside an effect, such as a `modify` body, it compiles but is reported and dropped. The effect starts after `interact` returns, runs until its first suspension before `sendViewEvent(_:)` returns, and resumes on the shell's isolation after every suspension.
- `try effects.modify { … }` commits a change: one commit and one test entry, however many members it sets. It throws only once the model is gone.
- Re-sending `.queryChanged` cancels the previous search: handling an action case cancels the anonymous effects that case started before. Cancellation is cooperative, and a cancelled effect's `modify` is still committed, so put `try Task.checkCancellation()` right before a result a newer action made stale. It is mandatory after `try?` or `catch`.
- An error that leaves a live effect is reported as `Effect threw: …`, which fails tests. Catch the errors you expect and turn them into state; a `catch` that writes an error checks `Task.checkCancellation()` or `Task.isCancelled` first, never `error is CancellationError`.
- An effect sends an action (`try effects.send(.next)`) only to start new effects, run interactor logic that a parent, a sibling or a `When` reacts to, or cancel by action case. `effects.send` during `interact` is reported and dropped.
- Sequential work is one effect doing the steps in order; concurrent work is several `perform` calls; a stream is a `for await` loop inside one effect.
- Dependencies are plain protocols or classes. Mark their async methods `nonisolated(nonsending)` unless your module enables `NonisolatedNonsendingByDefault`: a plain `async` method is `@concurrent` there, and calling it on a captured non-`Sendable` dependency fails with `sending '…' risks causing data races`.
- Effects run on the shell: CPU-bound work runs on the main actor under `ViewModel`. Move it behind a `@concurrent` function.

Debouncing, timers, `@EffectID`, streams and composition are covered in `resources/advanced-composition.md`. Test features with `TestModel`; see the `lattice-testing` skill.

## Shells

One nonisolated core runs the feature, only ever on the isolation of the shell that hosts it:

- `ViewModel`: `@MainActor`, for SwiftUI (iOS 17, macOS 14, watchOS 10).
- `ActorModel`: an actor with an executor of its own, for features that are not bound to a view (iOS 26, macOS 26, watchOS 26). Its `init` is `async`, `await model.send(.sync)?.value` waits for that send's effects, and reading `await model.state` from outside needs `State: Sendable`. It is not `Observable`, and it cancels its effects asynchronously when it is released.
- `TestModel`, the primary test shell, and `TestViewModel`, on the main actor: see the `lattice-testing` skill.

An interactor formed in main-actor-isolated code, such as a module with main-actor default isolation or a `@MainActor` context, cannot be handed to `ActorModel` or `TestModel`; such features use `ViewModel` and `TestViewModel`.

## Bindings from SwiftUI

Use `@Bindable` on `ViewModel` and derive bindings with `sending`.

```swift
@CasePathable
enum FormAction {
    case nameChanged(String)
}

@Bindable var viewModel: ViewModel<Feature<FormAction, FormState>>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

- Actions must be `@CasePathable` to use `sending`.
- Binding key paths are rooted at `FormState.ViewState`, so a `@Domain` member cannot be bound.
- A write sends the action and discards the task `sendViewEvent(_:)` returns.
- For enum state case bindings, use `sending(_:default:)` when case presence is conditional.

## Child features

Model a child feature as a nested `@FeatureState` member of the parent state (or as an enum-case payload).
Prefer composing interactors rather than nesting logic in views.
Use `when(state:action:child:)` or `Interactors.When` for scoped child handling. The child's effects write back into the parent state through the `When`, and its sends are embedded into parent actions.

## Scoped child views

Decouple child views from the parent's `ViewModel` type with `scope(state:action:)`, which returns a stateless `ScopedViewModel<ChildState, ChildAction>`:

```swift
// Parent body
HeaderView(model: viewModel.scope(state: \.header, action: \.header))

// Child view
struct HeaderView: View {
    let model: ScopedViewModel<HeaderState, HeaderAction>

    var body: some View {
        Text(model.title)
        Button("Refresh") { model.sendViewEvent(.refreshTapped) }
    }
}
```

- Do read members through the scope (`model.title`) for fine-grained observation; don't read the whole `model.viewState` (coarse: it re-renders only when the child is replaced).
- Do create scopes inline in `body`; don't store them (`@State` etc.) — a scope retains its parent view model.
- `model.sendViewEvent(_:)` embeds the child action into the parent action and returns the parent's `Task<Void, Never>?`.
- Optional children scope to `ScopedViewModel?`; a collection of `Identifiable` children (`Array` or `IdentifiedArrayOf`) scopes to one scope per element for `ForEach` (`scope(state: \.rows, action: \.row)` with `case row(RowState.ID, RowAction)`).
- For an enum state, use `viewModel.scope(state: \.success, action: \.success)` inside a matched `switch viewModel.viewState` case (traps if inactive) or `scopeIfActive(state:action:)` when the case may be inactive. Both go through the `@CasePathable` `ViewState` mirror, so the payload must be `@FeatureState`.
- Details and more overloads (closure embedding, read-only, nested scopes, bindings) in `resources/advanced-composition.md`.

## File layout for enum states

A known Swift 6.4 compiler bug can crash the compiler (segfault in `TypeCheckPrimaryFileRequest`) when a source file holds a `@FeatureState` enum together with other macro-annotated declarations (other `@FeatureState` types, `@CasePathable` enums, `@Observable` classes, `@Interactor` types, …). Declare each `@FeatureState` enum, `@CasePathable` or not, in its own file with no other macro-annotated declaration; put its payload structs, actions and interactor in other files. Files whose `@FeatureState` types are all structs are not affected. This is a temporary workaround for the compiler bug, not a design rule.

## References
- See `resources/advanced-composition.md` for composition, effect identity, debouncing, timers, navigation, and stream guidance.
- See `resources/bootstrapping.md` for state modeling, DI boundaries, and feature setup.
