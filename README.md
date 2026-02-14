# Lattice

Lattice is a Swift 6 library for building features with MVVM + unidirectional data flow.
It uses native Swift concurrency and supports iOS 17+, macOS 14+, and watchOS 10+.

## Core Features

- Unidirectional flow: views send actions, interactors mutate domain state, reducers derive view state.
- Feature-based API: `ViewModel` is parameterized by a single feature type (`ViewModel<F>`).
- Async effects: `.none`, `.action`, `.perform`, `.observe`, and `.merge` emissions.
- SwiftUI integration: `@ObservableState`, `@Bindable`, dynamic member lookup, and `EventTask`.
- Test tooling: `InteractorTestHarness`, `AsyncStreamRecorder`, and clock-based testing support.

## Installation

Add package dependency:

```swift
dependencies: [
    .package(url: "https://github.com/mibattaglia/swift-lattice", from: "1.0.0")
]
```

Add product dependency:

```swift
.target(
    name: "MyApp",
    dependencies: ["Lattice"]
)
```

## Quick Start

### 1. Domain and actions

```swift
struct CounterState: Sendable, Equatable {
    var count = 0
}

enum CounterAction: Sendable {
    case increment
    case decrement
}
```

### 2. Interactor

```swift
import Lattice

@Interactor<CounterState, CounterAction>
struct CounterInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
            case .decrement:
                state.count -= 1
            }
            return .none
        }
    }
}
```

### 3. View state + reducer

```swift
@ObservableState
struct CounterViewState: Sendable, Equatable {
    var countText = "0"
}

@ViewStateReducer<CounterState, CounterViewState>
struct CounterViewStateReducer: Sendable {
    func initialViewState(for domainState: CounterState) -> CounterViewState {
        CounterViewState()
    }

    var body: some ViewStateReducerOf<Self> {
        BuildViewState { domainState, viewState in
            viewState.countText = String(domainState.count)
        }
    }
}
```

### 4. ViewModel and SwiftUI

```swift
import SwiftUI

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialDomainState: CounterState(),
        feature: Feature(
            interactor: CounterInteractor(),
            reducer: CounterViewStateReducer()
        )
    )

    var body: some View {
        VStack {
            Text(viewModel.viewState.countText)
            HStack {
                Button("-") { viewModel.sendViewEvent(.decrement) }
                Button("+") { viewModel.sendViewEvent(.increment) }
            }
        }
    }
}
```

If domain state and view state are the same type, initialize `Feature` with only an interactor:

```swift
let viewModel = ViewModel(
    initialDomainState: CounterState(),
    feature: Feature(interactor: CounterInteractor())
)
```

## Architecture

1. The view sends an action via `sendViewEvent(_:)`.
2. The interactor mutates domain state and returns an `Emission<Action>`.
3. `ViewStateReducer` updates `viewState` from domain state.
4. Async emissions spawn tasks and can dispatch more actions.
5. `EventTask` can `finish()` or be cancelled by callers.

## Bindings

Use `@Bindable` with case-path actions:

```swift
@CasePathable
enum FormAction: Sendable {
    case nameChanged(String)
}

@ObservableState
struct FormViewState: Sendable, Equatable {
    var name = ""
}

@Bindable var viewModel: ViewModel<Feature<FormAction, FormDomainState, FormViewState>>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

## Testing

Run all tests:

```bash
swift test
```

Run library tests only:

```bash
swift test --filter LatticeTests
```

Run macro tests only:

```bash
swift test --filter LatticeMacrosTests
```

Run focused presentation tests:

```bash
swift test --filter FeatureViewModelTests
swift test --filter ViewModelBindingTests
swift test --filter ViewModelTests
```

## Development

Build all targets:

```bash
swift build
```

Format sources and tests:

```bash
swift-format format --in-place --recursive Sources Tests
```

Rebuild checked-in macro binary after macro source changes:

```bash
scripts/rebuild-macro.sh
```

Set `SKIP_LATTICE_MACRO_BUILD=1` to skip macro build steps when needed.

## Project Layout

- `Sources/Lattice`: runtime library (interactors, view model, emissions, testing helpers).
- `Sources/LatticeMacros`: macro implementations.
- `Macros/`: checked-in macro tool binary for tooling/Xcode.
- `ExampleProject/`: sample app and package-based examples.
- `Tests/`: library and macro tests.
