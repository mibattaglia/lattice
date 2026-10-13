# Lattice

Lattice is a Swift 6 library for building features with MVVM + unidirectional data flow.
It uses native Swift concurrency and supports iOS 17+, macOS 14+, and watchOS 10+.

## Core Features

- Unidirectional flow: views send actions, the interactor mutates the feature's one state, and views re-render from the members they read.
- One state per feature: `@FeatureState` generates the `ViewState` projection views read through; `@Domain` hides a member from views at compile time and keeps it observation-tracked.
- Feature-based API: `ViewModel` is parameterized by a single feature type (`ViewModel<F>`).
- Async effects: `.none`, `.action`, `.perform`, `.observe`, `.merge`, and `.append` emissions.
- Effect-level debouncing: `Emission.debounce(using:)` / `Debouncer`, and `Interactors.Debounce` for one-shot `.perform` effects.
- Interactor composition: `Interactors.When`, `when(state:action:child:)`, `Merge`, and `MergeMany`.
- View composition: `scope(state:action:)` and `ScopedViewModel` project fine-grained child states, optional children, collections, and enum-case payloads (`scopeIfActive`).
- SwiftUI integration: `@Bindable`, dynamic member lookup over the `ViewState` projection, and `EventTask`.
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

### 1. State and actions

```swift
import Foundation
import Lattice

@FeatureState
struct CounterState: Sendable, Equatable {
    var count = 0
}

enum CounterAction: Sendable {
    case increment
    case decrement
}
```

`@FeatureState` tracks each stored member for observation and generates `CounterState.ViewState`, the projection views read through. A file that declares a `@FeatureState` type needs `Observation` in scope; importing `Foundation` or `SwiftUI` provides it.

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

### 3. Presentation members

There is no separate view-state type. Display values are computed members of the state, and members that views must not read are marked `@Domain`:

```swift
@FeatureState
struct CounterState: Sendable, Equatable {
    @Domain var count = 0
    var countText: String { String(count) }
}
```

`count` stays observation-tracked, so a view that reads `countText` re-renders when `count` changes, but `CounterState.ViewState` does not expose `count`.

### 4. ViewModel and SwiftUI

```swift
import SwiftUI

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialState: CounterState(),
        feature: Feature(interactor: CounterInteractor())
    )

    var body: some View {
        VStack {
            Text(viewModel.countText)
            HStack {
                Button("-") { viewModel.sendViewEvent(.decrement) }
                Button("+") { viewModel.sendViewEvent(.increment) }
            }
        }
    }
}
```

`viewModel.countText` reads through `CounterState.ViewState`. Reading a `@Domain` member does not compile:

```text
viewModel.count  // error: 'count' is unavailable: 'count' is @Domain state and is not visible to views
```

`Feature(interactor:)` compares states with `==` when the state is `Equatable`. Pass `areStatesEqual:` when the state is not `Equatable` or when a custom comparison is the right boundary:

```swift
let feature = Feature(
    interactor: CounterInteractor(),
    areStatesEqual: { lhs, rhs in lhs.count == rhs.count }
)
```

## Architecture

1. The view sends an action via `sendViewEvent(_:)`.
2. `ViewModel` applies the synchronous interactor step immediately on the main actor.
3. The interactor mutates a working copy of the state and returns an `Emission<Action>`. The copy shares the state's observation registrars, so each member change notifies only the observers of that member.
4. `ViewModel` commits the new state. A wholesale replacement with equal content (per `areStatesEqual`) is dropped, so observers keep their registrations; only a new root identity re-renders views that read the whole `viewState`.
5. Async emissions spawn tasks and can dispatch more actions back into the same root send scope, whether they are concurrent (`.merge`) or sequential (`.append`).
6. `EventTask.finish()` waits transitively for that root scope to become quiescent, and `cancel()` cancels the currently tracked work in the scope.

Views read members (`viewModel.title`, `viewModel.badge.count`) for fine-grained observation. `viewModel.viewState` is the coarse read of the whole projection: it re-renders on a wholesale replacement or an enum case change, while members read off it stay fine-grained.

## State Modeling with Lattice

Each feature has one state type, and its interactor is the only code that mutates it. `@FeatureState` generates a `ViewState` projection of that state, and views read the state only through it. That boundary keeps tests expressive and decoupled from SwiftUI, keeps debugging simple, and keeps business data out of the rendering layer.

- Visible members: rendering instructions. Think strings, colors, visibility flags, and composed presentation models, usually computed from the members below.
- `@Domain` members: the business-logic model. Raw values (`Date`, IDs), workflow state, and external models when they are domain-aligned. They stay observation-tracked, so computed members that read them re-render when they change.
- The interactor: the only mutator. It applies actions synchronously and connects to external systems.

### Keep Views Dumb

Views and view controllers should render state and send actions. Formatting logic, complex branching, and business rules should stay out of the rendering layer.

- Why: it keeps UI tests focused on rendering, keeps business logic testable without SwiftUI, and reduces debugging surface area.
- Rule: if a value needs formatting for display, expose a computed member that formats it and keep the raw value `@Domain`.

### What Belongs in `@Domain`

- Raw `Date` or unformatted numeric values that the UI must interpret.
- API/DB DTOs (unless they already are presentation models).
- Business-rule-only state that never affects rendering.

Reading a `@Domain` member from a view, a scope, or a binding is a compile error.

### Layer Boundaries and External Data

- Views: send actions and render members of `State.ViewState`.
- Interactors: mutate the state and connect to external systems (`APIClient`, `DBClient`, etc.) via dependencies.
- Computed members: convert domain data to display language.
- Flow: view action -> interactor mutation/effect -> state update -> re-render of the views that read a changed member.

For BFF/server-driven or inert UI features, leave every member visible: the state already is the render model.

### Counter + API Modeling Example

```swift
import Foundation
import Lattice

struct CounterAPIModel: Codable, Sendable, Equatable {
    let count: Int
    let updatedAt: Date
}

@FeatureState
struct CounterState: Sendable, Equatable {
    var title = "Counter"
    @Domain var count = 0
    @Domain var lastUpdatedAt: Date?

    var countText: String { "\(count)" }

    var lastUpdatedText: String {
        guard let lastUpdatedAt else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastUpdatedAt, relativeTo: .now)
    }
}

enum CounterAction: Sendable {
    case task
    case hydrated(CounterAPIModel)
}

protocol CounterClient: Sendable {
    func fetch() async throws -> CounterAPIModel
}

@Interactor<CounterState, CounterAction>
struct CounterInteractor: Sendable {
    let counterClient: CounterClient

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .task:
                return .perform { [counterClient] in
                    guard let model = try? await counterClient.fetch() else { return nil }
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
```

`Text(viewModel.lastUpdatedText)` re-renders when `lastUpdatedAt` changes, while `viewModel.lastUpdatedAt` does not compile. Computed members are recomputed on each read; a derived value that is expensive to compute can be a visible stored member that the interactor keeps in sync.

### Known Issue: One `@FeatureState` Enum per File

A known Swift 6.4 compiler bug can crash the compiler (a segfault in `TypeCheckPrimaryFileRequest`) when a source file holds a `@FeatureState` enum together with other macro-annotated declarations: other `@FeatureState` types, `@CasePathable` enums, `@Observable` classes, `@Interactor` types, and so on. Declare each `@FeatureState` enum, `@CasePathable` or not, in its own file with no other macro-annotated declaration. Files whose `@FeatureState` types are all structs are not affected. This is a temporary layout rule that works around the compiler bug, not a design choice; see [`specs/feature-state.md`](specs/feature-state.md#limitations).

## Bindings

Use `@Bindable` with case-path actions:

```swift
@CasePathable
enum FormAction: Sendable {
    case nameChanged(String)
}

@FeatureState
struct FormState: Sendable, Equatable {
    var name = ""
}

@Bindable var viewModel: ViewModel<Feature<FormAction, FormState>>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

Binding key paths are rooted at `FormState.ViewState`, so `$viewModel.member` rejects a `@Domain` member at compile time.

For a `@CasePathable` enum state, bindings reach the members of a case payload through the generated `ViewState` mirror. In the Search example, whose state has `case results(ResultState)`:

```swift
$viewModel.results.query.sending(\.search.query)
$viewModel.results.query.sending(\.search.query, default: "")
```

`sending(_:)` traps if the state is in a different case. Use `sending(_:default:)` when the view may access a binding while the state is in a different case.

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

`ViewModel.scope(state:action:)` projects a parent view model onto a child `@FeatureState` member and a child action space, so child views depend only on their own `ScopedViewModel<ChildState, ChildAction>` instead of the parent's `ViewModel` type.

```swift
@CasePathable
enum DashboardAction: Sendable {
    case header(HeaderAction)
    case footer(FooterAction)
}

struct DashboardView: View {
    @State private var viewModel: ViewModel<Feature<DashboardAction, DashboardState>>

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
        Button("Refresh") { model.sendViewEvent(.refreshTapped) }
    }
}
```

`ScopedViewModel` is a stateless value type: it owns no state, effects, or lifecycle, so it is cheap to recreate on every render. Reads walk the parent's live `@FeatureState` getter chain through `ChildState.ViewState`, so child views observe fine-grained and the child's `@Domain` members stay hidden; sends embed into the parent action and return the parent's `EventTask`.

- Read members through the scope (`model.title`, `model.badge.count`) for fine-grained observation. Reading the whole `model.viewState` value is coarse: it re-renders only when the child is replaced (or, for an enum child, changes case).
- Create scopes inline in `body`; do not store them in `@State` or long-lived properties (a scope retains its parent view model).
- Optional children: `scope(state: \.detail, action: \.detail)` returns `nil` while `detail` is `nil`.
- Collections: over an `Array` or `IdentifiedArrayOf` of `Identifiable` child states, `scope(state: \.rows, action: \.row)` returns one `Identifiable` scope per element, ready for `ForEach`. The action case carries the element id (`case row(RowState.ID, RowAction)`). An `IdentifiedArrayOf` finds each element in O(1), an `Array` in O(n).
- Overloads: case-path action embedding (shown above), a closure-based `scope(state:action:)` for non-`CasePathable` actions, and a read-only `scope(state:)` whose action type is `Never`.
- Scopes compose: `ScopedViewModel.scope(state:action:)` projects a grandchild through the parent.
- Two-way bindings: `model.binding(\.name, sending: \.nameChanged)`.

```swift
ForEach(viewModel.scope(state: \.rows, action: \.row)) { row in
    RowView(model: row)
}
```

### Enum-case scoping

When the state is a `@CasePathable` `@FeatureState` enum, its generated `ViewState` is a `@CasePathable` mirror enum. Switch over `viewModel.viewState` and scope onto the active case's payload:

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

Reads through a case scope are live — in-place payload mutations are observed fine-grained — and the scope serves a creation snapshot for at most one transitional render if the case flips while the view is still on screen. Sends that arrive after a case flip should be dropped by the interactor (`Interactors.When` over a case path drops them).

Case scoping needs a `@FeatureState` payload: the mirror case holds the payload's `ViewState`, so the payload's `@Domain` members stay hidden and its edits are observed per member. A plain payload (`String`, a DTO) is exposed raw and observed coarsely: a content change re-renders every view that switches over the state. Make payload structs the feature owns `@FeatureState`, and keep primitive and foreign payloads plain. A case with several payload values (`.failed(message:retryCount:)`) currently does not re-render those views on a payload content change; see the limitations in [`specs/feature-state.md`](specs/feature-state.md#limitations).

See `ExampleProject/ScopedCompositionExamplePackage` for a runnable demo of both styles, and `specs/scoped-view-composition.md` / `specs/enum-case-scoping.md` for design details.

## Testing with `TestViewModel`

Use `TestViewModel<F>` for state-first, step-wise feature tests. Its assertion APIs are
non-throwing, so you call them without `try`.

```swift
let feature = Feature(interactor: SearchInteractor())
let model = TestViewModel(
    initialState: SearchState(),
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
- `state` always reflects the last asserted or received state, not newer buffered emission output. It is the raw state, `@Domain` members included.
- Assertions compare states with the feature's `areStatesEqual`; `Feature(interactor:)` supplies `==` for an `Equatable` state. For a state that is not `Equatable`, pass `areStatesEqual:` to `Feature(interactor:areStatesEqual:)` or to `TestViewModel(initialState:feature:areStatesEqual:)`; the feature's own equality takes precedence. Without either, `TestViewModel` reports an issue at `init` and every state assertion fails.
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

Run the `@FeatureState` macro expansion snapshots:

```bash
swift test --filter FeatureStateMacroTests
swift test --filter FeatureStateSupportMacrosTests
```

Run the `ViewState` projection runtime tests:

```bash
swift test --filter ProjectionTests
swift test --filter ViewStateProjectionTests
swift test --filter ViewStateCollectionTests
```

Run focused presentation tests:

```bash
swift test --filter FeatureViewModelTests
swift test --filter ViewModelBindingTests
swift test --filter ViewModelTests
swift test --filter ScopedViewModelTests
swift test --filter EnumCaseScopingTests
swift test --filter FineGrainedObservationTests
swift test --filter ViewModelObservationTests
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

Check that `@Domain` members stay hidden from views (CI runs this after the build):

```bash
swift build
bash scripts/negative-compile-checks.sh
```

The script type-checks `Tests/NegativeCompileChecks` against the built module. The fixtures must compile without flags, and each `LEAK_*` flag (a `@Domain` member reached through the view model, a child, an optional child, a collection element, a key path, a binding, a scope or an enum payload, and the raw state) and `GENERIC_STATE` must fail with its expected diagnostic. Pass the build's options in `SWIFT_BUILD_FLAGS` when they are not the defaults, for example `SWIFT_BUILD_FLAGS="--scratch-path <dir>"`.

Run the projection read benchmark (release only; it is compiled out of debug builds):

```bash
swift test -c release --filter ProjectionReadBenchmark
```

## Development

Lattice requires Swift 6.2 tools or later: `Package.swift` declares `swift-tools-version: 6.2` and is the package's only manifest.

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

- `Sources/Lattice`: runtime library (interactors, `FeatureState` observation and `ViewState` projections, view model, emissions, testing helpers).
- `Sources/LatticeMacros`: macro implementations.
- `Macros/`: checked-in macro tool binary for tooling/Xcode.
- `ExampleProject/`: sample app and package-based examples.
- `Tests/`: library and macro tests, plus `Tests/NegativeCompileChecks`, the fixtures of `scripts/negative-compile-checks.sh` (not a SwiftPM target).
- `specs/`: source-driven design and behavior docs.
