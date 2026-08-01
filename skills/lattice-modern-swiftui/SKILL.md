---
name: lattice-modern-swiftui
description: Build SwiftUI features with Lattice ViewModel, @Bindable bindings, and clear view actions.
license: MIT
metadata:
  short-description: Modern SwiftUI patterns for Lattice.
---

# Lattice Modern SwiftUI

## Goal

Build SwiftUI views that are thin, deterministic, and easy to preview by routing all feature logic through Lattice's `ViewModel` and `Interactor`, with one `@FeatureState` state type per feature.

## Core rules

- Views send user events through `sendViewEvent(_:)` and read visible members straight off the view model (`viewModel.displayText`) through the generated projection.
- `sendViewEvent(_:)` returns an `EventTask` over the effects that send launched. Await `finish()` in `.task`, `.refreshable`, or explicit `Task` blocks when the UI must wait for downstream work.
- Mark interactor-only members `@Domain`; visible computed properties on the state type are the view contract (formatted strings, flags, presentation values).
- Move multi-line logic out of view closures into methods named after user actions.
- Reading a `@Domain` member from a view does not compile — derive what the view needs as a visible computed property instead.

## View wiring patterns

### Single @FeatureState type

```swift
@FeatureState
struct CounterState {
    @Domain var count = 0
    var displayText: String { "Count: \(count)" }
}

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialState: CounterState(),
        interactor: CounterInteractor()
    )

    var body: some View {
        VStack {
            Text(viewModel.displayText)
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

There is no separate ViewState type and no reducer: the state's visible members are what views
read, and the commit diff re-renders a view only when a member it reads actually changed.

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
@Bindable var viewModel: ViewModel<FormState, FormAction>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

For enum state case bindings, use `sending(_:default:)` when the case may not be active.

## Scoped child views

Pass child views a `ScopedViewModel` instead of the parent's `ViewModel` type. Create scopes inline in `body` with `scope(state:action:)`:

```swift
struct DashboardView: View {
    @State private var viewModel: ViewModel<DashboardState, DashboardAction>

    var body: some View {
        VStack {
            HeaderView(model: viewModel.scope(state: \.header, action: \.header))
            FooterView(model: viewModel.scope(state: \.footer, action: \.footer))
        }
    }
}

struct HeaderView: View {
    let model: ScopedViewModel<HeaderState, HeaderAction>

    var body: some View {
        Text(model.title) // fine-grained: re-renders only when `title` changes
        TextField("Name", text: model.binding(\.name, sending: \.nameChanged))
        Button("Refresh") { model.sendViewEvent(.refreshTapped) }
    }
}
```

Rules:

- Read members through the scope (`model.title`, `model.badge.count`) — reads go through the child's projection, so observation stays per member.
- Create scopes inline in `body`. Never store a scope in `@State` or another long-lived property; it retains the parent view model.
- Case-path action embedding requires the parent action to be `@CasePathable`; use the closure overload `scope(state:action: { .child($0) })` otherwise.
- `scope(state:)` with no action produces a read-only scope (`ChildAction == Never`) for display-only children.
- `model.sendViewEvent(_:)` returns the parent's `EventTask`; await `finish()` for async boundaries just like on `ViewModel`.

### Enum state

Switch over the projected enum and scope onto the matched case's payload via the generated case accessors:

```swift
switch viewModel.route {
case .loading:
    ProgressView()
case .success:
    SuccessView(model: viewModel.scope(state: \.success, action: \.success))
}
```

The trapping `scope(state:action:)` is safe inside a matched `switch` case (body evaluation is synchronous). Outside a matched case, use `scopeIfActive(state:action:)`, which returns `nil` when the case is inactive.

## Presentation

Keep navigation and presentation decisions in the feature state. Use optional `@FeatureState` members or enum cases, then drive SwiftUI modifiers from projected reads:

```swift
@FeatureState
struct ScreenState {
    var destination: DestinationState?
}

if let destination = viewModel.destination {
    // present from the projected child
}
```
