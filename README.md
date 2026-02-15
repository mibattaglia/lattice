# Lattice

Lattice is a Swift 6 library for building features with MVVM + unidirectional data flow.
It uses native Swift concurrency and supports iOS 17+, macOS 14+, and watchOS 10+.

## Core Features

- Unidirectional flow: views send actions, interactors mutate domain state, reducers derive view state.
- Feature-based API: `ViewModel` is parameterized by a single feature type (`ViewModel<F>`).
- Async effects: `.none`, `.action`, `.perform`, `.observe`, and `.merge` emissions.
- Effect-level debouncing: `Emission.debounce(using:)` and `Interactors.Debounce`.
- Interactor composition: `Interactors.When`, `when(state:action:child:)`, `Merge`, and `MergeMany`.
- SwiftUI integration: `@ObservableState`, `@Bindable`, dynamic member lookup, and `EventTask`.
- Test tooling: `InteractorTestHarness`, `AsyncStreamRecorder`, and clock-based testing support.

## Installation

Add package dependency:

```swift
dependencies: [
    .package(url: "https://github.com/mibattaglia/swift-lattice", from: "0.1.0")
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
struct CounterDomainState: Sendable, Equatable {
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

@Interactor<CounterDomainState, CounterAction>
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
struct CounterViewState: Sendable, Equatable, DefaultValueProvider {
    static let defaultValue = CounterViewState()
    var countText = "0"
}

@ViewStateReducer<CounterDomainState, CounterViewState>
struct CounterViewStateReducer: Sendable {
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
        initialDomainState: CounterDomainState(),
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
    initialDomainState: CounterDomainState(),
    feature: Feature(interactor: CounterInteractor())
)
```

Customize domain-state equality when state is not `Equatable` or when identity-based comparisons are preferred:

```swift
let feature = Feature(
    interactor: CounterInteractor(),
    reducer: CounterViewStateReducer(),
    areStatesEqual: { lhs, rhs in lhs.version == rhs.version }
)
```

## Architecture

1. The view sends an action via `sendViewEvent(_:)`.
2. The interactor mutates domain state and returns an `Emission<Action>`.
3. A stateless `ViewStateReducer` updates `viewState` from domain state.
4. Async emissions spawn tasks and can dispatch more actions.
5. `EventTask` can `finish()` or be cancelled by callers.

## State Modeling with Lattice

Lattice separates `DomainState` from `ViewState` to make tests more expressive and decoupled from SwiftUI, make debugging simpler, and enforce clean boundaries.

- `DomainState`: the business-logic model for a feature. It can include raw values (`Date`, IDs), workflow state, and external models when they are domain-aligned.
- `ViewState`: rendering instructions only. Think strings, colors, visibility flags, and composed presentation models.
- `ViewStateReducer`: the translation boundary. It is synchronous and stateless, and boils domain data into presentation-ready values.

### Keep Views Dumb

Views and view controllers should render state and send actions. Formatting logic, complex branching, and business rules should stay out of the rendering layer.

- Why: it keeps UI tests focused on rendering, keeps business logic testable without SwiftUI, and reduces debugging surface area.
- Rule: if a value needs formatting for display, reduce it before it reaches the view.

### What Does Not Belong in ViewState

- Raw `Date` or unformatted numeric values that the UI must interpret.
- API/DB DTOs (unless they already are presentation models).
- Business-rule-only state that never affects rendering.

### Layer Boundaries and External Data

- Views: send actions and render `ViewState`.
- Interactors: mutate `DomainState` and connect to external systems (`APIClient`, `DBClient`, etc.) via dependencies.
- Reducers: convert domain data to display language.
- Flow: view action -> interactor mutation/effect -> domain update -> reducer projection -> render.

For BFF/server-driven or inert UI features, the lightweight `Feature(interactor:)` path is valid when `DomainState == ViewState`.

### Counter + API Modeling Example

```swift
import Foundation
import Lattice

struct CounterAPIModel: Codable, Sendable, Equatable {
    let count: Int
    let updatedAt: Date
}

struct CounterDomainState: Sendable, Equatable {
    var count = 0
    var lastUpdatedAt: Date?
}

@ObservableState
struct CounterViewState: Sendable, Equatable, DefaultValueProvider {
    static let defaultValue = CounterViewState()
    var title = "Counter"
    var countText = "0"
    var lastUpdatedText = "Never"
}

enum CounterAction: Sendable {
    case task
    case hydrated(CounterAPIModel)
}

protocol CounterClient: Sendable {
    func fetch() async throws -> CounterAPIModel
}

@Interactor<CounterDomainState, CounterAction>
struct CounterInteractor: Sendable {
    let counterClient: CounterClient

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .task:
                return .perform { [counterClient] in
                    let model = try await counterClient.fetch()
                    return .hydrated(model)
                }
            case .hydrated(let model):
                state.count = model.count
                state.lastUpdatedAt = model.updatedAt
                return .none
            }
        }
    }
}

@ViewStateReducer<CounterDomainState, CounterViewState>
struct CounterViewStateReducer: Sendable {
    var body: some ViewStateReducerOf<Self> {
        BuildViewState { domainState, viewState in
            viewState.countText = "\(domainState.count)"
            viewState.lastUpdatedText = Self.renderLastUpdated(domainState.lastUpdatedAt)
        }
    }

    static func renderLastUpdated(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
```

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

For `CasePathable` enum view state, bindings can be scoped to case members:

```swift
$viewModel.detail.title.sending(\.detailTitleChanged, default: "")
```

Use `sending(_:default:)` when the view may access a binding while the state is in a different case.

## Debouncing

Debounce effect emissions while preserving immediate state updates:

```swift
import Clocks

@Interactor<SearchState, SearchAction>
struct SearchInteractor: Sendable {
    let searchClient: SearchClient
    let debouncer = Debouncer<ContinuousClock, SearchAction?>(for: .milliseconds(300), clock: .init())

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .queryChanged(let query):
                state.query = query
                return .perform { [searchClient] in
                    let results = await searchClient.search(query)
                    return .searchResponse(results)
                }
                .debounce(using: debouncer)
            case .searchResponse:
                return .none
            }
        }
    }
}
```

Or wrap a child interactor:

```swift
Interactors.Debounce(for: .milliseconds(300)) {
    SearchInteractor()
}
```

## Composition

Scope child features with case paths or key paths:

```swift
parentInteractor.when(state: \.childState, action: \.child) {
    ChildInteractor()
}
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

Run focused debounce tests:

```bash
swift test --filter EmissionDebounceTests
swift test --filter DebounceInteractorTests
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

Set `SKIP_LATTICE_MACRO_BUILD=1` or `SKIP_LATTICE_MACRO_BUILD=true` to skip macro build steps when needed.

Sync local Codex and Claude skill folders:

```bash
scripts/sync-skills.sh
```

## Project Layout

- `Sources/Lattice`: runtime library (interactors, view model, emissions, testing helpers).
- `Sources/LatticeMacros`: macro implementations.
- `Macros/`: checked-in macro tool binary for tooling/Xcode.
- `ExampleProject/`: sample app and package-based examples.
- `Tests/`: library and macro tests.
