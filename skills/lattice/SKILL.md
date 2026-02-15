---
name: lattice
description: Build Swift application features using Lattice interactors, view models, and view state reducers.
license: MIT
metadata:
  short-description: Build features with Lattice.
---

# Lattice Architecture

## Goal

Build Swift features using Lattice's Interactor + ViewModel + ViewStateReducer architecture.
For new feature setup, use the bootstrap checklist in `resources/bootstrapping.md`.

## State modeling rules

- `DomainState` is business logic state. It can hold raw values and domain-aligned external models.
- `ViewState` is render instructions only. Keep raw formatting concerns out of views.
- Interactors own side effects and external data access via dependencies.
- `ViewStateReducer` is a synchronous, stateless translation from domain data to presentation values.
- Prefer Interactor + reducer layering; use interactor-only features for lightweight BFF/server-driven or inert UI paths.

## Quick start

1. Add the `swift-lattice` package dependency.
2. Add the `Lattice` product to your target's dependencies.
3. `import Lattice` as needed.

## Build a basic feature

```swift
import Lattice

struct CounterState: Sendable, Equatable {
    var count = 0
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
- Do keep domain state in the interactor; view state is derived.

## Connect to SwiftUI

```swift
import Lattice
import SwiftUI

@ObservableState
struct CounterViewState: Sendable, Equatable, DefaultValueProvider {
    static let defaultValue = CounterViewState(countText: "0")
    var countText = "0"
}

@ViewStateReducer<CounterState, CounterViewState>
struct CounterViewStateReducer: Sendable {
    var body: some ViewStateReducerOf<Self> {
        BuildViewState { domainState, viewState in
            viewState.countText = String(domainState.count)
        }
    }
}

struct CounterView: View {
    @State var viewModel = ViewModel(
        initialDomainState: CounterState(),
        feature: Feature(
            interactor: CounterInteractor(),
            reducer: CounterViewStateReducer()
        )
    )

    var body: some View {
        HStack {
            Button("-") { viewModel.sendViewEvent(.decrementButtonTapped) }
            Text(viewModel.viewState.countText)
            Button("+") { viewModel.sendViewEvent(.incrementButtonTapped) }
        }
    }
}
```

- Do keep view methods thin; move multi-line logic to private methods named after user actions.
- Do use `@ObservableState` on view state types.
- `BuildViewState { domainState, viewState in ... }` is the standard reducer style.
- If view state does not conform to `DefaultValueProvider`, provide `initialViewState(for:)`.
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
                    let results = try await searchClient.search(query)
                    return .searchResponse(results)
                }
            case .searchResponse(let results):
                state.results = results
                return .none
            }
        }
    }
}
```

Advanced effect orchestration techniques (debouncing, stream observation, and composition) are covered in `resources/advanced-composition.md`.

## Bindings from SwiftUI

Use `@Bindable` on `ViewModel` and derive bindings with `sending`.

```swift
@CasePathable
enum FormAction: Sendable {
    case nameChanged(String)
}

@Bindable var viewModel: ViewModel<Feature<FormAction, FormState, FormViewState>>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

- Actions must be `@CasePathable` to use `sending`.
- For enum view state case bindings, use `sending(_:default:)` when case presence is conditional.

## Child features

Model child state in domain, and use `ViewStateReducer` to derive view state as needed.
Prefer composing interactors rather than nesting logic in views.
Use `when(state:action:child:)` or `Interactors.When` for scoped child handling.

## References
- See `resources/advanced-composition.md` for composition, navigation, and stream guidance.
- See `resources/bootstrapping.md` for state modeling, DI boundaries, and feature setup.
