# UnoArchitecture

A lightweight, pure Swift library for building complex features using MVVM with unidirectional data flow. Built on Swift's native async/await and AsyncStream.

## Features

- **Unidirectional Data Flow**: Actions flow in, state flows out
- **AsyncStream-Based**: Native Swift concurrency with no Combine dependency
- **Declarative Composition**: Result builders for composing interactors
- **Type-Safe**: Strong generic constraints ensure compile-time safety
- **Testable**: First-class testing support with `InteractorTestHarness` and `AsyncStreamRecorder`
- **SwiftUI Integration**: Generic `ViewModel` class for seamless view binding
- **Swift 6 Ready**: Full concurrency safety with `@MainActor` isolation

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mibattaglia/swift-uno-architecture", from: "1.0.0")
]
```

Then add `UnoArchitecture` to your target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: ["UnoArchitecture"]
)
```

## Quick Start

### 1. Define Domain State and Actions

```swift
struct CounterState: Sendable, Equatable {
    var count: Int = 0
}

enum CounterAction: Sendable {
    case increment
    case decrement
}
```

### 2. Create an Interactor

```swift
import UnoArchitecture

@Interactor<CounterState, CounterAction>
struct CounterInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact(initialValue: CounterState()) { state, action in
            switch action {
            case .increment:
                state.count += 1
            case .decrement:
                state.count -= 1
            }
            return .state
        }
    }
}
```

### 3. Create a ViewModel

The `ViewModel` class connects your interactor to SwiftUI. There are two initialization patterns:

**Direct Pattern** (when DomainState == ViewState):

```swift
// Use DirectViewModel when your interactor output is your view state
let viewModel: DirectViewModel<CounterAction, CounterState> = ViewModel(
    CounterState(count: 0),
    CounterInteractor().eraseToAnyInteractor()
)
```

This pattern is useful when you have a simple feature that does not need complex 
mappings between your feature's domain and the rendering instructions for your
feature's view.

**Full Pattern** (with ViewStateReducer):

```swift
// Use the full ViewModel when you need to transform domain state to view state
let viewModel = ViewModel(
    initialValue: CounterViewState(count: 0, displayText: ""),
    CounterInteractor().eraseToAnyInteractor(),
    CounterViewStateReducer().eraseToAnyViewStateReducer()
)
```

You'll want to use the full pattern with an `Interactor` and `ViewStateReducer`
when you have complex state to manage in your feature. 

One of the main tenet's of Uno is that a feature's ViewState should be simple
(think mainly primitives like strings, colors, etc.). The `ViewStateReducer` pattern
is helpful when transforming a complex accumulated model into simple rendering instructions
for your view.  

### 4. Connect to SwiftUI

```swift
struct CounterView: View {
    @StateObject var viewModel: CounterViewModel

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

The `Interactor` protocol transforms a stream of actions into a stream of domain state:

```swift
func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState>
```

Use the `@Interactor` macro for a declarative definition:

```swift
@Interactor<MyState, MyAction>
struct MyInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact(initialValue: MyState()) { state, action in
            // Handle action, mutate state
            return .state
        }
    }
}
```

### Emission Types

The `Emission` type controls how state is emitted:

- **`.state`**: Emit the current state immediately
- **`.perform { state, send in ... }`**: Execute async work, then emit via `send`
- **`.observe { state, send in ... }`**: Observe a stream, emitting for each element

```swift
// Async work example
return .perform { state, send in
    let data = try await api.fetchData()
    var newState = await state.current
    newState.data = data
    await send(newState)
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
        .when(stateIs: \.child, actionIs: \.childAction, stateAction: \.setChild) {
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
        BuildViewState { domainState in
            CounterViewState(
                count: domainState.count,
                displayText: "Count: \(domainState.count)"
            )
        }
    }
}
```

## Testing

Use `InteractorTestHarness` for testing interactors:

```swift
@Test
func testIncrement() async throws {
    let harness = await InteractorTestHarness(CounterInteractor())

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

- iOS 16.0+ / macOS 14.0+ / watchOS 10.0+
- Swift 6.0+
- Xcode 16.0+

## Dependencies

- [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) - AsyncSequence operators
- [swift-case-paths](https://github.com/pointfreeco/swift-case-paths) - Enum case access
- [swift-clocks](https://github.com/pointfreeco/swift-clocks) - Testable time control

## Documentation

- [Architecture Guide](docs/architecture.md)
- [API Reference](docs/api/)
- [Testing Guide](docs/testing/testing-guide.md)
- [Migration from Combine](docs/migration/combine-to-asyncstream.md)

## License

MIT License - see [LICENSE](LICENSE) for details.
