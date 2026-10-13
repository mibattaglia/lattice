---
name: lattice
description: Build Swift application features using Lattice interactors, features, view models, and @FeatureState state.
license: MIT
metadata:
  short-description: Build features with Lattice.
---

# Lattice Architecture

## Goal

Build Swift features using Lattice's Interactor + Feature + ViewModel architecture over one `@FeatureState` state per feature.
For new feature setup, use the bootstrap checklist in `resources/bootstrapping.md`.

## State modeling rules

- A feature has one `@FeatureState` state, and its interactor is the only code that mutates it.
- Views read the state through the generated `State.ViewState` projection. Visible members are render instructions; derive display values as computed members on the state.
- Mark business-logic members (raw values, workflow flags, domain-aligned external models) `@Domain`. They stay observation-tracked, so computed members that read them re-render, but views, scopes and bindings cannot read them.
- Interactors own side effects and external data access via dependencies.
- Keep raw formatting concerns out of views.

## Quick start

1. Add the `swift-lattice` package dependency.
2. Add the `Lattice` product to your target's dependencies.
3. `import Lattice` as needed. A file that declares a `@FeatureState` type also needs `Observation` in scope (`import Foundation` or `import SwiftUI` provides it).
4. `@Interactor<State, Action>` requires explicit generic arguments.

## Build a basic feature

```swift
import Foundation
import Lattice

@FeatureState
struct CounterState: Sendable, Equatable {
    @Domain var count = 0
    var countText: String { String(count) }
}

enum CounterAction: Sendable {
    case decrementButtonTapped
    case incrementButtonTapped
}

@Interactor<CounterState, CounterAction>
struct CounterInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .decrementButtonTapped:
                state.count -= 1
                return .none
            case .incrementButtonTapped:
                state.count += 1
                return .none
            }
        }
    }
}
```

- Do name actions after user intent (`incrementButtonTapped`), not the state change.
- Do keep raw values `@Domain` and expose display values as computed members; there is no separate view-state type or reducer.

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
- `sendViewEvent(_:)` returns an `EventTask`; use `finish()` when the view must await root-scope completion, and `cancel()` when lifecycle-bound work should stop.
- `Feature(interactor:)` compares states with `==` when the state is `Equatable`. Pass `areStatesEqual:` when the state is not `Equatable` or when a version/identity comparison is the right boundary.
- Don't push formatting (`Date` to text, enum display labels, color decisions) into SwiftUI views.

## Async work

Use `.perform` or `.observe` emissions from the interactor.

```swift
enum SearchAction: Sendable {
    case queryChanged(String)
    case searchResponse([String])
}

@Interactor<SearchState, SearchAction>
struct SearchInteractor: Sendable {
    let searchClient: SearchClient

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .queryChanged(let query):
                state.query = query
                return .perform { [searchClient] in
                    do {
                        let results = try await searchClient.search(query)
                        return .searchResponse(results)
                    } catch {
                        return nil
                    }
                }
            case .searchResponse(let results):
                state.results = results
                return .none
            }
        }
    }
}
```

- `.perform` returns `Action?`; return `nil` when cancelled work or error handling should emit nothing.
- Use `.append`, `appending(with:)`, or `.then(...)` when follow-up emissions must run sequentially.
Advanced effect orchestration techniques (debouncing, stream observation, and composition) are covered in `resources/advanced-composition.md`.

## Bindings from SwiftUI

Use `@Bindable` on `ViewModel` and derive bindings with `sending`.

```swift
@CasePathable
enum FormAction: Sendable {
    case nameChanged(String)
}

@Bindable var viewModel: ViewModel<Feature<FormAction, FormState>>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

- Actions must be `@CasePathable` to use `sending`.
- Binding key paths are rooted at `FormState.ViewState`, so a `@Domain` member cannot be bound.
- For enum state case bindings, use `sending(_:default:)` when case presence is conditional.

## Child features

Model a child feature as a nested `@FeatureState` member of the parent state (or as an enum-case payload).
Prefer composing interactors rather than nesting logic in views.
Use `when(state:action:child:)` or `Interactors.When` for scoped child handling.

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
- Optional children scope to `ScopedViewModel?`; a collection of `Identifiable` children (`Array` or `IdentifiedArrayOf`) scopes to one scope per element for `ForEach` (`scope(state: \.rows, action: \.row)` with `case row(RowState.ID, RowAction)`).
- For an enum state, use `viewModel.scope(state: \.success, action: \.success)` inside a matched `switch viewModel.viewState` case (traps if inactive) or `scopeIfActive(state:action:)` when the case may be inactive. Both go through the `@CasePathable` `ViewState` mirror, so the payload must be `@FeatureState`.
- Details and more overloads (closure embedding, read-only, nested scopes, bindings) in `resources/advanced-composition.md`.

## File layout for enum states

A known Swift 6.4 compiler bug can crash the compiler (segfault in `TypeCheckPrimaryFileRequest`) when a source file holds a `@FeatureState` enum together with other macro-annotated declarations (other `@FeatureState` types, `@CasePathable` enums, `@Observable` classes, `@Interactor` types, …). Declare each `@FeatureState` enum, `@CasePathable` or not, in its own file with no other macro-annotated declaration; put its payload structs, actions and interactor in other files. Files whose `@FeatureState` types are all structs are not affected. This is a temporary workaround for the compiler bug, not a design rule.

## References
- See `resources/advanced-composition.md` for composition, navigation, and stream guidance.
- See `resources/bootstrapping.md` for state modeling, DI boundaries, and feature setup.
