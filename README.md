# Lattice

A lightweight, pure Swift library for building complex features using MVVM with unidirectional data flow. Built on Swift's native async/await.
Inspired by The Composable Architecture.

## Features

- **Unidirectional Data Flow**: Actions flow in, state flows out
- **Async/Await-Based**: Native Swift concurrency with no Combine dependency
- **Declarative Composition**: Result builders for composing interactors
- **Type-Safe**: Strong generic constraints ensure compile-time safety
- **Testable**: First-class testing support with `InteractorTestHarness` and `AsyncStreamRecorder`
- **SwiftUI Integration**: Generic `ViewModel` class with `@Bindable` bindings and `EventTask`
- **ObservableState Macro**: View state types get Observation conformance automatically
- **Swift 6 Ready**: Full concurrency safety with `@MainActor` isolation

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mibattaglia/swift-lattice", from: "1.0.0")
]
```

Then add `Lattice` to your target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: ["Lattice"]
)
```

## Quick Start

### 1. Define Domain State, View State, and Actions

```swift
struct CounterState: Sendable, Equatable {
    var count: Int = 0
}

enum CounterAction: Sendable {
    case increment
    case decrement
}

@ObservableState
struct CounterViewState: Sendable, Equatable {
    var count: Int = 0
    var displayText: String = ""
}
```

### 2. Create an Interactor

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

### 3. Create a ViewModel

The `ViewModel` class connects your interactor to SwiftUI. Two initialization patterns are supported:

**Direct Pattern** (when DomainState == ViewState):

```swift
// Use DirectViewModel when your interactor output is your view state
let viewModel: DirectViewModel<CounterAction, CounterState> = ViewModel(
    initialState: CounterState(count: 0),
    interactor: CounterInteractor().eraseToAnyInteractor()
)
```

This pattern fits a simple feature that does not need complex mappings between
domain state and view rendering instructions.

**Full Pattern** (with ViewStateReducer):

```swift
// Use the full ViewModel when you need to transform domain state to view state
let viewModel = ViewModel(
    initialDomainState: CounterState(count: 0),
    initialViewState: CounterViewState(count: 0, displayText: ""),
    interactor: CounterInteractor().eraseToAnyInteractor(),
    viewStateReducer: CounterViewStateReducer().eraseToAnyReducer()
)
```

Use the full pattern with an `Interactor` and `ViewStateReducer` when your feature
needs a richer domain state.

One of the main tenets of Lattice is that a feature's ViewState should be simple,
mostly primitives like strings and colors. The `ViewStateReducer` pattern helps
transform a complex domain model into clear rendering instructions for your view.

### 4. Connect to SwiftUI

```swift
struct CounterView: View {
    @State var viewModel = ViewModel(
        initialDomainState: CounterState(count: 0),
        initialViewState: CounterViewState(count: 0, displayText: ""),
        interactor: CounterInteractor().eraseToAnyInteractor(),
        viewStateReducer: CounterViewStateReducer().eraseToAnyReducer()
    )

    var body: some View {
        VStack {
            Text("Count: \(viewModel.viewState.count)")

            HStack {
                Button("-") { viewModel.sendViewEvent(.decrement) }
                Button("+") { viewModel.sendViewEvent(.increment) }
            }
        }
    }
}
```

## Architecture Overview

```
+---------------------+
|    SwiftUI View     |
+----------+----------+
           | sendViewEvent()
           v
+---------------------+
|     ViewModel       |  <-- Generic ViewModel<Action, DomainState, ViewState>
+----------+----------+
           |
           v
+---------------------+
|     Interactor      |  <-- @Interactor macro
+----------+----------+
           |
           v
+---------------------+
|  ViewStateReducer   |  <-- @ViewStateReducer macro (optional with DirectViewModel)
+---------------------+
           | flows back to ViewModel
           v
+---------------------+
|     ViewModel       | 
+---------------------+
           | setting `ViewState` triggers a re-render
           v
+---------------------+
|    SwiftUI View     |
+----------+----------+
```

**Data Flow**:
1. **View** sends events via `sendViewEvent(_:)`
2. **ViewModel** forwards events to the **Interactor**
3. **Interactor** processes events and emits new domain state
4. **ViewStateReducer** transforms domain state to view state
5. **ViewModel** publishes view state changes
6. **View** re-renders with new view state

## Core Concepts

### Interactor

The `Interactor` protocol processes an action by mutating state and returning an `Emission`:

```swift
func interact(state: inout DomainState, action: Action) -> Emission<Action>
```

Use the `@Interactor` macro for a declarative definition:

```swift
@Interactor<MyState, MyAction>
struct MyInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            // Handle action, mutate state
            return .none
        }
    }
}
```

### Emission Types

The `Emission` type controls how state is emitted:

- **`.none`**: No action to emit
- **`.action(action)`**: Emit an action immediately
- **`.perform { ... }`**: Execute async work, return an optional action
- **`.observe { ... }`**: Observe a stream, emitting actions for each element

```swift
// Async work example
return .perform { [api] in
    let data = try await api.fetchData()
    return .dataLoaded(data)
}
```

### Higher-Order Interactors

Compose interactors declaratively:

```swift
var body: some InteractorOf<Self> {
    // Merge multiple interactors
    LoggingInteractor()
    AnalyticsInteractor()

    // Debounce actions
    DebounceInteractor(for: .milliseconds(300)) {
        SearchInteractor()
    }

    // Scope to child state/action
    ParentInteractor()
        .when(state: \.child, action: \.childAction) {
            ChildInteractor()
        }
}
```

### ViewStateReducer

Transforms domain state into view-friendly state:

```swift
@ViewStateReducer<CounterState, CounterViewState>
struct CounterViewStateReducer: Sendable {
    var body: some ViewStateReducerOf<Self> {
        BuildViewState { domainState, viewState in
            viewState.count = domainState.count
            viewState.displayText = "Count: \(domainState.count)"
        }
    }
}
```

### ObservableState

Only view states must conform to `ObservableState`. Domain state does not need to be observable.
Use the macro to generate the required Observation conformance:

```swift
@ObservableState
struct MyViewState: Sendable, Equatable {
    var title: String = ""
    var count: Int = 0
}
```

### SwiftUI Bindings

Use `@Bindable` with a `ViewModel` to create bindings that send actions:

```swift
@Bindable var viewModel: ViewModel<Action, State, ViewState>

TextField("Name", text: $viewModel.name.sending(\.updateName))
```

`sendViewEvent(_:)` returns an `EventTask`, so you can await or cancel effects:

```swift
await viewModel.sendViewEvent(.refresh).finish()
```

## Testing

Use `InteractorTestHarness` for testing interactors:

```swift
@Test
func testIncrement() async throws {
    let harness = InteractorTestHarness(
        initialState: CounterState(count: 0),
        interactor: CounterInteractor()
    )

    harness.send(.increment)
    harness.send(.increment)

    try await harness.assertStates([
        CounterState(count: 0),  // Initial state
        CounterState(count: 1),
        CounterState(count: 2)
    ])
}
```

For time-based testing, inject a `TestClock`:

```swift
@Test
func testDebounce() async throws {
    let clock = TestClock()
    let interactor = DebounceInteractor(for: .seconds(1), clock: clock) {
        SearchInteractor()
    }
    // Control time advancement with clock.advance(by:)
}
```

## Development

After cloning, configure git to use the project's hooks:

```bash
git config core.hooksPath .githooks
```

This enables the pre-push hook which auto-formats Swift files with `swift-format`.

## Requirements

- iOS 17.0+ / macOS 14.0+ / watchOS 10.0+
- Swift 6.0+
- Xcode 16.0+

## Dependencies

- [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) - AsyncSequence operators
- [swift-case-paths](https://github.com/pointfreeco/swift-case-paths) - Enum case access
- [swift-clocks](https://github.com/pointfreeco/swift-clocks) - Testable time control
- [combine-schedulers](https://github.com/pointfreeco/combine-schedulers) - Scheduler utilities
- [swift-collections](https://github.com/apple/swift-collections) - Ordered/identified collections
- [swift-identified-collections](https://github.com/pointfreeco/swift-identified-collections) - Identified data
- [swift-syntax](https://github.com/apple/swift-syntax) - Macro support
- [swift-macro-testing](https://github.com/pointfreeco/swift-macro-testing) - Macro testing utilities

## Documentation

- [Architecture Guide](docs/architecture.md)
- [API Reference](docs/api/)
- [Testing Guide](docs/testing/testing-guide.md)
- [Migration from Combine](docs/migration/combine-to-asyncstream.md)

## License

MIT License - see [LICENSE](LICENSE) for details.

## Inspiration and Credit

Lattice is inspired by [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).
The builder pattern, effect pattern, and `ObservableState` are all derived from TCA's architecture and conventions.
