---
name: lattice-observable-models
description: Move SwiftUI logic into Lattice interactors and view models while keeping views thin.
license: MIT
metadata:
  short-description: Observable models for Lattice features.
---

# Lattice Observable Models

## Goal

Prefer Lattice's `Interactor` + `ViewModel` architecture for feature logic, while using Swift `@Observable` models only for local, UI-scoped behavior that does not belong in the interactor.

## Primary rule

If logic affects domain state, side effects, or async work, model it in the `Interactor`. Views should only translate user events into actions via `sendViewEvent(_:)`.

## When a local observable model is acceptable

- View-only state (focus, selection, animation flags).
- Temporary UI state that is not part of the feature's domain state.
- UI helpers that do not trigger emissions or side effects.

## Patterns

### Prefer Interactor + ViewModel

```swift
@Interactor<CounterState, CounterAction>
struct CounterInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none
            }
        }
    }
}

struct CounterView: View {
    @State var viewModel = ViewModel(
        initialDomainState: CounterState(count: 0),
        feature: Feature(
            interactor: CounterInteractor(),
            reducer: CounterViewStateReducer()
        )
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
    @State var viewModel = ViewModel(...)
    @State var toast = ToastState()

    var body: some View {
        Button("Show") { toast.isVisible = true }
    }
}
```

## Async work

Async work must live in the interactor. Views can create a `Task` when they need to await `EventTask` completion.

```swift
Button("Refresh") { Task { await viewModel.sendViewEvent(.refresh).finish() } }
```

For advanced effect orchestration patterns (time, streams, composition), use the feature's interactor and corresponding architecture/testing guides.

## Naming

- Action cases and view methods are named after the user action ("refreshButtonTapped", `.refreshTapped`).
- Interactor methods are avoided; keep logic in the interactor body.
