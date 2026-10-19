---
name: lattice-modern-swiftui
description: Build SwiftUI features with Lattice ViewModel, @Bindable bindings, clear view actions, and the task sendViewEvent returns.
license: MIT
metadata:
  short-description: Modern SwiftUI patterns for Lattice.
---

# Lattice Modern SwiftUI

## Goal

Build SwiftUI views that are thin, deterministic, and easy to preview by routing all feature logic through Lattice's `ViewModel` and `Interactor`, and by reading one `@FeatureState` state through its generated `ViewState` projection.

## Core rules

- Views send user events through `sendViewEvent(_:)` and read members of the state's `ViewState` (`viewModel.title`), or `viewModel.viewState` to `switch` over an enum state.
- `sendViewEvent(_:)` is synchronous. When it returns, the interactor has run, the state is committed, and every effect the action started has run until its first suspension.
- It returns a discardable `Task<Void, Never>?` for exactly the effects that send started: `nil` when it started none, and never the effects those effects start in turn. Cancelling the task cancels them.
- Keep visible members simple (strings, numbers, colors, booleans). Compute them on the state from `@Domain` raw values instead of transforming data in the view.
- Move multi-line logic out of view closures into methods named after user actions.
- `@Domain` members cannot be read from views, scopes, or bindings; expose a computed member instead.

## View wiring pattern

```swift
@FeatureState
struct CounterState: Equatable {
    @Domain var count = 0
    var displayText: String { "Count: \(count)" }
}

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialState: CounterState(),
        feature: Feature(interactor: CounterInteractor())
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

`viewModel.displayText` is observed on its own: the view re-renders when `count` changes because `displayText` reads it, and not when unrelated members change.

## Async actions from the view

A button only sends. The effect runs on its own and writes its result into the state, which re-renders the view:

```swift
Button("Refresh") { viewModel.sendViewEvent(.refresh) }
```

Await the returned task only where SwiftUI expects an async boundary and the effect ends by itself, as in `.refreshable`:

```swift
.refreshable {
    await viewModel.sendViewEvent(.refresh)?.value
}
```

A `.task` that starts a long-lived effect, such as a ticker or a stream, forwards its own cancellation. SwiftUI cancels the `.task` closure when the view goes away, but awaiting `Task.value` does not cancel the effects:

```swift
.task {
    let ticker = viewModel.sendViewEvent(.startTicking)
    await withTaskCancellationHandler {
        await ticker?.value
    } onCancel: {
        ticker?.cancel()
    }
}
```

- Without the handler, `await viewModel.sendViewEvent(.startTicking)?.value` would leave the ticker running until `.startTicking` is sent again or the view model is deallocated.
- The interactor performs the ticker without a guard: re-sending `.startTicking`, as a view that appears again does, cancels the running ticker, so there is never more than one.
- Deallocating the view model cancels its effects too. Released on the main actor, its `isolated deinit` cancels them before the release returns.
- Effects run on the main actor under `ViewModel`. Keep CPU-bound work behind a `@concurrent` function or a dependency with its own executor.

## Bindings

Use `@Bindable` to derive bindings that send actions on write. Avoid `Binding(get:set:)` and prefer the Lattice binding helpers.
Action enums must be `@CasePathable` to use `sending`.

```swift
@Bindable var viewModel: ViewModel<Feature<FormAction, FormState>>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

A write sends the action and discards the task `sendViewEvent(_:)` returns. For enum state case bindings, use `sending(_:default:)` when the case may not be active.

## Scoped child views

Pass child views a `ScopedViewModel` instead of the parent's `ViewModel` type. Create scopes inline in `body` with `scope(state:action:)`:

```swift
struct DashboardView: View {
    @State private var viewModel: ViewModel<Feature<DashboardAction, DashboardState>>

    var body: some View {
        VStack {
            HeaderView(model: viewModel.scope(state: \.header, action: \.header))
            FooterView(model: viewModel.scope(state: \.footer, action: \.footer))
            BadgeView(model: viewModel.scope(state: \.header.badge)) // read-only, action type is Never
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

- Read members through the scope (`model.title`, `model.badge.count`); reading the whole `model.viewState` is coarse and misses in-place leaf mutations.
- Create scopes inline in `body`. Never store a scope in `@State` or another long-lived property; it retains the parent view model.
- Case-path action embedding requires the parent action to be `@CasePathable`; use the closure overload `scope(state:action: { .child($0) })` otherwise.
- `scope(state:)` with no action produces a read-only scope (`ChildAction == Never`) for display-only children.
- Collections of `Identifiable` children scope element by element: `ForEach(viewModel.scope(state: \.rows, action: \.row)) { row in RowView(model: row) }`.
- `model.sendViewEvent(_:)` embeds the child action into the parent action and returns the parent's `Task<Void, Never>?`; await its `value`, or forward cancellation to it, just like on `ViewModel`.

### Enum state

Switch over the enum and scope onto the matched case's payload:

```swift
switch viewModel.viewState {
case .loading:
    ProgressView()
case .success:
    SuccessView(model: viewModel.scope(state: \.success, action: \.success))
}
```

The trapping `scope(state:action:)` is safe inside a matched `switch` case (body evaluation is synchronous). Outside a matched case, use `scopeIfActive(state:action:)`, which returns `nil` when the case is inactive. The payload must be `@FeatureState` to be scoped.

## Presentation

Keep navigation and presentation decisions in the state. Use optional children or enum cases, derive presentation flags as computed members, and drive SwiftUI modifiers from them:

```swift
@FeatureState
struct ScreenState: Equatable {
    var detail: DetailState?
    var isShowingDetail: Bool { detail != nil }
}

@Bindable var viewModel: ViewModel<Feature<ScreenAction, ScreenState>>

.sheet(isPresented: $viewModel.isShowingDetail.sending(\.detailPresentationChanged)) {
    if let detail = viewModel.scope(state: \.detail, action: \.detail) {
        DetailView(model: detail)
    }
}
```
