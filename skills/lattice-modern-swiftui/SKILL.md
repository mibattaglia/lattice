---
name: lattice-modern-swiftui
description: Build SwiftUI features with Lattice ViewModel, @Bindable bindings, and clear view actions.
license: MIT
metadata:
  short-description: Modern SwiftUI patterns for Lattice.
---

# Lattice Modern SwiftUI

## Goal

Build SwiftUI views that are thin, deterministic, and easy to preview by routing all feature logic through Lattice's `ViewModel`, `Interactor`, and `ViewStateReducer`.

## Core rules

- Views send user events through `sendViewEvent(_:)` and read from `viewState`.
- `sendViewEvent(_:)` returns an `EventTask` scoped to that root send. Await `finish()` in `.task`, `.refreshable`, or explicit `Task` blocks when the UI must wait for downstream work.
- Keep view state simple (strings, numbers, colors, booleans). Use a `ViewStateReducer` to transform domain state.
- Move multi-line logic out of view closures into methods named after user actions.
- Use `Feature(interactor:)` only when `DomainState == ViewState`; otherwise model an explicit reducer.
- If a reducer-backed view state does not conform to `DefaultValueProvider`, implement `initialViewState(for:)`.

## View wiring patterns

### Feature with ViewStateReducer (DomainState -> ViewState)

```swift
struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialDomainState: CounterState(count: 0),
        feature: Feature(
            interactor: CounterInteractor(),
            reducer: CounterViewStateReducer()
        )
    )

    var body: some View {
        VStack {
            Text(viewModel.viewState.displayText)
            HStack {
                Button("-") { decrementButtonTapped() }
                Button("+") { incrementButtonTapped() }
            }
        }
    }

    private func decrementButtonTapped() {
        viewModel.sendViewEvent(.decrement)
    }

    private func incrementButtonTapped() {
        viewModel.sendViewEvent(.increment)
    }
}
```

### Feature without reducer (DomainState == ViewState)

```swift
@ObservableState
struct CounterState: Sendable, Equatable {
    var count = 0
}

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialDomainState: CounterState(),
        feature: Feature(interactor: CounterInteractor())
    )

    var body: some View {
        Text("Count: \(viewModel.viewState.count)")
    }
}
```

## Async actions from the view

```swift
Button("Refresh") {
    Task { await refreshButtonTapped() }
}

private func refreshButtonTapped() async {
    await viewModel.sendViewEvent(.refresh).finish()
}
```

`.refreshable` and `.task` are good fits when SwiftUI already expects an async boundary:

```swift
.refreshable {
    await viewModel.sendViewEvent(.refresh).finish()
}
```

## Bindings

Use `@Bindable` to derive bindings that send actions on write. Avoid `Binding(get:set:)` and prefer the Lattice binding helpers.
Action enums must be `@CasePathable` to use `sending`.

```swift
@Bindable var viewModel: ViewModel<Feature<Action, DomainState, ViewState>>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

For enum view state case bindings, use `sending(_:default:)` when the case may not be active.

## Scoped child views

Pass child views a `ScopedViewModel` instead of the parent's `ViewModel` type. Create scopes inline in `body` with `scope(state:action:)`:

```swift
struct DashboardView: View {
    @State private var viewModel: ViewModel<DashboardFeature>

    var body: some View {
        VStack {
            HeaderView(model: viewModel.scope(state: \.header, action: \.header))
            FooterView(model: viewModel.scope(state: \.footer, action: \.footer))
            BadgeView(model: viewModel.scope(state: \.header.badge)) // read-only, action type is Never
        }
    }
}

struct HeaderView: View {
    let model: ScopedViewModel<HeaderViewState, HeaderAction>

    var body: some View {
        Text(model.title) // fine-grained: re-renders only when `title` changes
        TextField("Name", text: model.binding(\.name, sending: \.nameChanged))
        Button("Refresh") { model.sendViewEvent(.refreshTapped) }
    }
}
```

Rules:

- Read members through the scope (`model.title`, `model.badge.count`); reading the whole `model.viewState` is coarse and misses in-place leaf mutations.
- Create scopes inline in `body`. Never store a scope in `@State` or another long-lived property; it retains the parent view model.
- Case-path action embedding requires the parent action to be `@CasePathable`; use the closure overload `scope(state:action: { .child($0) })` otherwise.
- `scope(state:)` with no action produces a read-only scope (`ChildAction == Never`) for display-only children.
- `model.sendViewEvent(_:)` returns the parent's `EventTask`; await `finish()` for async boundaries just like on `ViewModel`.

### Enum view state

Switch over the enum and scope onto the matched case's payload:

```swift
switch viewModel.viewState {
case .loading:
    ProgressView()
case .success:
    SuccessView(model: viewModel.scope(state: \.success, action: \.success))
}
```

The trapping `scope(state:action:)` is safe inside a matched `switch` case (body evaluation is synchronous). Outside a matched case, use `scopeIfActive(state:action:)`, which returns `nil` when the case is inactive.

## Presentation

Keep navigation and presentation decisions in ViewState. Use optional state or enum cases, then drive SwiftUI modifiers from view state.

```swift
@ObservableState
struct ScreenViewState: Sendable, Equatable {
    var destination: DestinationViewState?
}

@Bindable var viewModel: ViewModel<Feature<Action, DomainState, ScreenViewState>>

.sheet(item: $viewModel.destination) { destination in
    DestinationView(viewState: destination)
}
```
