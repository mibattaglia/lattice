---
name: lattice
description: Build Swift application features using Lattice interactors, features, view models, and feature state projections.
license: MIT
metadata:
  short-description: Build features with Lattice.
---

# Lattice Architecture

## Goal

Build Swift features using Lattice's Interactor + `@FeatureState` + ViewModel architecture.
For new feature setup, use the bootstrap checklist in `resources/bootstrapping.md`.

## State modeling rules

- One state type per feature, annotated `@FeatureState`.
- `@Domain` members are business-logic state: raw values, workflow state, domain-aligned external models. They are invisible to views.
- Every other member — stored or computed — is the view contract. Visible computed properties are derived view output, diffed by output at commit.
- Interactors own side effects and external data access via plain (non-`Sendable`) dependencies.
- No `Sendable` conformances anywhere: state, actions, interactors, and dependencies live in the feature's isolation domain.

## Quick start

1. Add the `swift-lattice` package dependency (Swift 6.2 toolchain required).
2. Add the `Lattice` product to your target's dependencies.
3. `import Lattice` as needed.
4. `@Interactor<DomainState, Action>` requires explicit generic arguments; `@FeatureState` attaches to the state type.

## Build a basic feature

```swift
import Lattice

@FeatureState
struct CounterState {
    var count: Int = 0
    var countText: String { "\(count)" }
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
- One state type: annotate it `@FeatureState`. Mark interactor-only members `@Domain`;
  everything else — stored or computed — is what views read (`viewModel.count`,
  `viewModel.countText`). There is no separate ViewState type and no reducer: visible
  computed properties *are* the derived view output, diffed by output at commit.
- Visible stored members need an explicit type annotation (`var count: Int = 0`) — the macro
  builds the projection from the declared types.
- No `Sendable` conformances anywhere: state, actions, interactors, and dependencies are plain
  types living in the feature's isolation domain.
- Pure state mutation uses the two-argument `Interact { state, action in }` overload; take the
  third `effects` parameter only when you launch async work.

## Connect to SwiftUI

```swift
import Lattice
import SwiftUI

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialState: CounterState(),
        interactor: CounterInteractor()
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

- Views read visible members straight off the view model (`viewModel.countText`) through the
  generated projection; observation is per member, so a view re-renders only when a member it
  reads actually changed.
- Do keep view methods thin; move multi-line logic to private methods named after user actions.
- `sendViewEvent(_:)` returns an `EventTask`; use `finish()` when the view must await the
  effects the send launched, and `cancel()` when lifecycle-bound work should stop.
- Don't push formatting (`Date` to text, enum display labels, color decisions) into SwiftUI
  views — derive it as a visible computed property on the state.

## Async work

Launch effects imperatively with `effects.perform` during the synchronous update phase; effects
re-enter by mutating state directly with `effectState.modify`. There are no follow-up "response"
actions.

```swift
enum SearchAction {
    case queryChanged(String)
}

@Interactor<SearchState, SearchAction>
struct SearchInteractor {
    let searchClient: SearchClient   // plain protocol, no Sendable
    let clock: any Clock<Duration>

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .queryChanged(let query):
                state.query = query          // synchronous mutation, visible immediately
                state.isLoading = true
                effects.perform { [searchClient, clock] effectState in
                    try await clock.sleep(for: .milliseconds(300))   // debounce window
                    do {
                        let results = try await searchClient.search(query)
                        try effectState.modify { state in
                            state.isLoading = false
                            state.results = results
                        }
                    } catch {
                        try effectState.modify { state in
                            state.isLoading = false
                            state.results = []
                        }
                    }
                }
            }
        }
    }
}
```

- `effects.perform` is legal only during the update phase (inside `interact`); it launches the
  operation in the feature's isolation domain.
- `effectState.modify` is legal only from inside a launched effect; it throws `CancellationError`
  if the feature was torn down, so spell it `try effectState.modify { … }`.
- Re-dispatching the same action **replaces** the previous in-flight task at that action
  location — that auto-replacement plus `clock.sleep` *is* debouncing; there is no debounce API.
- Streams are `for await` loops inside `perform`:

```swift
case .task:
    effects.perform { effectState in
        for await status in networkMonitor.statusUpdates {
            effectState.isOnline = status.isConnected
        }
    }
```

- Sequential work is sequential `await`s inside one `perform` closure; concurrent work is
  multiple `perform` calls.
- Name a long-lived effect with `@EffectID var recording` and `effects.perform(id: recording)`
  to cancel (`effects.perform { _ in recording.cancel() }`) or await (`try await recording()`) it
  explicitly.
- CPU-bound work should hop off-domain via a consumer-side `@concurrent` function taking
  `sending` values, then re-enter with `effectState.modify`.

Advanced effect orchestration (streams, `EffectID`, composition, dismissal semantics) is
covered in `resources/advanced-composition.md`.

## Bindings from SwiftUI

Use `@Bindable` on `ViewModel` and derive bindings with `sending`.

```swift
@CasePathable
enum FormAction {
    case nameChanged(String)
}

@Bindable var viewModel: ViewModel<FormState, FormAction>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

- Actions must be `@CasePathable` to use `sending`.
- For enum state case bindings, use `sending(_:default:)` when case presence is conditional.

## Child features

Model child state as a member (or enum case) of the parent's `@FeatureState` type.
Prefer composing interactors rather than nesting logic in views.
Use `when(state:action:child:)` or `Interactors.When` for scoped child handling.
If the child's case departs (or the scoped optional becomes `nil`) while a child effect is in
flight, the child's tasks are cancelled and straggling `modify`/`send` calls are dropped
silently — the navigation-dismissed-mid-request contract.

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

- Do read members through the scope (`model.title`) for fine-grained observation.
- Do create scopes inline in `body`; don't store them (`@State` etc.) — a scope retains its parent view model.
- For enum state, use `viewModel.scope(state: \.success, action: \.success)` inside a matched `switch` case (traps if inactive) or `scopeIfActive(state:action:)` when the case may be inactive.
- Details and more overloads (closure embedding, read-only, nested scopes, bindings) in `resources/advanced-composition.md`.

## References
- See `resources/advanced-composition.md` for composition, navigation, and stream guidance.
- See `resources/bootstrapping.md` for state modeling, DI boundaries, and feature setup.
