# Lattice

Lattice is a Swift 6 library for building features with MVVM + unidirectional data flow.
It uses native Swift concurrency and supports iOS 17+, macOS 14+, and watchOS 10+.

## Core Features

- Unidirectional flow: views send actions, interactors mutate domain state, reducers derive view state.
- Feature-based API: `ViewModel` is parameterized by a single feature type (`ViewModel<F>`).
- Async effects: `.none`, `.action`, `.perform`, `.observe`, `.merge`, and `.append` emissions.
- Effect-level debouncing: `Emission.debounce(using:)` / `Debouncer`, and `Interactors.Debounce` for one-shot `.perform` effects.
- Interactor composition: `Interactors.When`, `when(state:action:child:)`, `Merge`, and `MergeMany`.
- View composition: `scope(state:action:)` and `ScopedViewModel` project fine-grained child slices of view state, including enum-case payloads via `scopeIfActive`.
- SwiftUI integration: `@ObservableState`, `@Bindable`, dynamic member lookup, and `EventTask`.
- Step-wise testing: `TestViewModel`, `TestEventTask`, exhaustivity, and clock-based testing support.

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
2. `ViewModel` applies the synchronous interactor step immediately on the main actor.
3. The interactor mutates domain state and returns an `Emission<Action>`.
4. A stateless `ViewStateReducer` updates `viewState` from domain state.
5. Async emissions spawn tasks and can dispatch more actions back into the same root send scope, whether they are concurrent (`.merge`) or sequential (`.append`).
6. `EventTask.finish()` waits transitively for that root scope to become quiescent, and `cancel()` cancels the currently tracked work in the scope.

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

`Interactors.Debounce` preserves immediate synchronous state updates, then debounces top-level one-shot `.perform` emissions with action-ordered cancel-in-flight behavior, closer to TCA's `sleep + cancellable(id:cancelInFlight:)` model.

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

For lower-level emission debouncing, `Debouncer` and `Emission.debounce(using:)` still exist separately.

Wrap a child interactor when you want the same runtime behavior around a feature:

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

## Scoped View Composition

`ViewModel.scope(state:action:)` projects a parent view model onto a child slice of view state and a child action space, so child views depend only on their own `ScopedViewModel<ChildState, ChildAction>` instead of the parent's `ViewModel` type.

```swift
@CasePathable
enum DashboardAction: Sendable {
    case header(HeaderAction)
    case footer(FooterAction)
}

struct DashboardView: View {
    @State private var viewModel: ViewModel<DashboardFeature>

    var body: some View {
        VStack {
            HeaderView(model: viewModel.scope(state: \.header, action: \.header))
            FooterView(model: viewModel.scope(state: \.footer, action: \.footer))
        }
    }
}

struct HeaderView: View {
    let model: ScopedViewModel<HeaderViewState, HeaderAction>

    var body: some View {
        Text(model.title) // fine-grained: re-renders only when `title` changes
        Button("Refresh") { model.sendViewEvent(.refreshTapped) }
    }
}
```

`ScopedViewModel` is a stateless value type: it owns no state, effects, or lifecycle, so it is cheap to recreate on every render. Reads walk the parent's live `@ObservableState` getter chain, so child views observe fine-grained; sends embed into the parent action and return the parent's `EventTask`.

- Read members through the scope (`model.title`, `model.badge.count`) for fine-grained observation. Reading the whole `model.viewState` value is coarse: it registers only the slice's identity and re-renders only on wholesale replacement.
- Create scopes inline in `body`; do not store them in `@State` or long-lived properties (a scope retains its parent view model).
- Overloads: case-path action embedding (shown above), a closure-based `scope(state:action:)` for non-`CasePathable` actions, and a read-only `scope(state:)` whose action type is `Never`.
- Scopes compose: `ScopedViewModel.scope(state:action:)` projects a grandchild slice through the parent.
- Two-way bindings: `model.binding(\.name, sending: \.nameChanged)`.

### Enum-case scoping

When view state is a `CasePathable` enum, scope onto the active case's payload:

```swift
switch viewModel.viewState {
case .loading:
    LoadingView()
case .success:
    SuccessView(model: viewModel.scope(state: \.success, action: \.success))
}
```

`scope(state:action:)` traps with `fatalError` if the case is not active; inside a matched `switch` case this cannot happen because body evaluation is synchronous. Use `scopeIfActive(state:action:)` when the case may legitimately be inactive:

```swift
if let success = viewModel.scopeIfActive(state: \.success, action: \.success) {
    SuccessView(model: success)
}
```

Reads through a case scope are live — in-place payload mutations are observed fine-grained — and the scope serves a creation snapshot for at most one transitional render if the case flips while the view is still on screen. Sends that arrive after a case flip should be dropped by the interactor.

See `ExampleProject/ScopedCompositionExamplePackage` for a runnable demo of both styles, and `specs/scoped-view-composition.md` / `specs/enum-case-scoping.md` for design details.

## Testing with `TestViewModel`

Use `TestViewModel<F>` for domain-state-first, step-wise feature tests. Its assertion APIs are
non-throwing, so you call them without `try`.

```swift
let feature = Feature(interactor: SearchInteractor())
let model = TestViewModel(
    initialDomainState: SearchState(),
    feature: feature
)

let task = await model.send(.queryChanged("lattice")) {
    $0.query = "lattice"
    $0.isLoading = true
}

await model.receive(.searchResponse(["Lattice"])) {
    $0.isLoading = false
    $0.results = ["Lattice"]
}

await task.finish()
```

`TestViewModel` semantics:

- `send` asserts the immediately visible state mutation and returns a `TestEventTask` for that root send scope.
- `domainState` always reflects the last asserted or received state, not newer buffered emission output.
- Actions emitted from emissions are buffered until you `receive` or `skipReceivedActions()`.
- `finish()` checks for unhandled receives before waiting for in-flight emission work.
- `TestEventTask.finish()` waits for root-scope quiescence only; it does not implicitly drain buffered receives.
- `skipInFlightEffects()` cancels and settles currently running emission work when a test needs to move past long-lived work.
- `exhaustivity` is on by default and enforces explicit handling of buffered receives.

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
swift test --filter ScopedViewModelTests
swift test --filter EnumCaseScopingTests
```

Run focused runtime and testing-infrastructure suites:

```bash
swift test --filter EventTaskTests
swift test --filter TestViewModel
swift test --filter Append
swift test --filter Observe
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

Formatting is handled by the pre-push hook with `swift-format`. Do not run `swift-format` manually.

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
