---
name: lattice-observable-models
description: Move SwiftUI logic into Lattice interactors, effects and view models while keeping views thin.
license: MIT
metadata:
  short-description: Observable models for Lattice features.
---

# Lattice Observable Models

## Goal

Prefer Lattice's `Interactor` + `ViewModel` architecture for feature logic, while using Swift `@Observable` models only for local, UI-scoped behavior that does not belong in the interactor.

## Primary rule

If logic affects the feature's state, side effects, or async work, model it in the `Interactor` and its effects. Views should only translate user events into actions via `sendViewEvent(_:)`.
Use the `Task<Void, Never>?` returned from `sendViewEvent(_:)` when the UI needs to await or cancel feature work; do not build a second `@Observable` coordinator just to manage async interactor behavior.

## When a local observable model is acceptable

- View-only state (focus, selection, animation flags).
- Temporary UI state that is not part of the feature's `@FeatureState` state.
- UI helpers that do not trigger effects or state mutations.

## Patterns

### Prefer Interactor + ViewModel

```swift
@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action, _ in
            switch action {
            case .increment:
                state.count += 1
            }
        }
    }
}

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialState: CounterState(count: 0),
        feature: Feature(interactor: CounterInteractor())
    )

    var body: some View {
        Button("+") { viewModel.sendViewEvent(.increment) }
    }
}
```

### Use a local @Observable model for UI-only state

```swift
@Observable
final class ToastState {
    var isVisible = false
}

struct ScreenView: View {
    @State private var viewModel = ViewModel(
        initialState: CounterState(count: 0),
        feature: Feature(interactor: CounterInteractor())
    )
    @State private var toast = ToastState()

    var body: some View {
        Button("Show") { toast.isVisible = true }
    }
}
```

Keep an `@Observable` class out of any file that declares a `@FeatureState` enum: that combination can crash the Swift 6.4 compiler (see the `lattice` skill).

## Async work

Async work must live in the interactor, as effects it performs with `effects.perform`; an effect writes its result into the state with `effects.modify`. Views can create a `Task` when they need to await the effects an action started:

```swift
Button("Refresh") { Task { await viewModel.sendViewEvent(.refresh)?.value } }
```

Awaiting the task does not cancel it. Inside `.task`, forward the cancellation instead, so the work stops with the view (see the `lattice-modern-swiftui` skill).

For advanced effect orchestration patterns (time, streams, composition), use the feature's interactor and corresponding architecture/testing guides.

## Naming

- Action cases and view methods are named after the user action ("refreshButtonTapped", `.refreshTapped`).
- Interactor methods are avoided; keep logic in the interactor body.
