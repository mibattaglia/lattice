# Lattice

Lattice is a Swift library for building features with MVVM + unidirectional data flow. The
feature tree lives in a single isolation domain — **no `Sendable` requirements on your
types** — and each feature carries **one annotated state type** that serves both the
interactor and the view. Lattice uses native Swift concurrency, requires Swift 6.2+, and
supports iOS 17+, macOS 14+, and watchOS 10+.

Migrating from 0.x? See [MIGRATING-1.0.md](MIGRATING-1.0.md).

## Core Features

- Unidirectional flow: views send actions, interactors mutate state, visible computed properties derive view output.
- One annotated state type: `@FeatureState` + `@Domain` collapse the domain/view split into a single struct or enum — no handwritten ViewState, no reducer type; the split survives as compile-checked member visibility.
- No `Sendable` requirements: the feature tree lives in one isolation domain; your state, actions, and dependencies never need `Sendable` conformances.
- Imperative effects: `effects.perform` launches async work during the synchronous update phase; effects re-enter by mutating state directly with `effectState.modify` — no follow-up-action ping-pong.
- Structural cancellation: in-flight effects are auto-replaced per perform call site (debounce/search-as-you-type for free), cancellable by `@EffectID`, and torn down when a `When` scope's state departs.
- Interactor composition: `Interactors.When`, `when(state:action:child:)`, `Merge`, and `MergeMany` over a static composition tree.
- View composition: `scope(state:action:)` and `ScopedViewModel` project fine-grained child slices of the view projection, including enum-case payloads.
- SwiftUI integration: views read `viewModel.someLabel` through a generated `@dynamicMemberLookup` projection; observation is per-member diff-at-commit, so a view re-renders only when a member it reads actually changed.
- Snapshot-diff testing: `TestViewModel` asserts every state change — synchronous mutations and effect re-entries alike — with exhaustive diffs.

## Installation

Requires a Swift 6.2 toolchain (Xcode 26) or later.

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

### 1. State and actions

```swift
import Lattice

@FeatureState
struct CounterState {
    var count: Int = 0
}

enum CounterAction {
    case increment
    case decrement
}
```

### 2. Interactor

```swift
@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
            case .decrement:
                state.count -= 1
            }
        }
    }
}
```

### 3. ViewModel and SwiftUI

```swift
import SwiftUI

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialState: CounterState(),
        interactor: CounterInteractor()
    )

    var body: some View {
        VStack {
            Text("\(viewModel.count)")
            HStack {
                Button("-") { viewModel.sendViewEvent(.decrement) }
                Button("+") { viewModel.sendViewEvent(.increment) }
            }
        }
    }
}
```

### Weather Search Example

A search feature: keystrokes debounce a network request by task replacement, results land via
direct state mutation from the effect, one annotated state type carries both the domain model
and the view contract, and nothing conforms to `Sendable`.

```swift
import Foundation
import IdentifiedCollections
import Lattice

// A plain protocol — no Sendable requirement, main-actor implementations welcome.
protocol WeatherClient {
    func search(query: String) async throws -> [WeatherResult]
}

// Each result is itself a feature state: stored domain data is fenced off with @Domain,
// and the visible computed properties are the row's rendering instructions.
@FeatureState
struct WeatherResult: Equatable, Identifiable {
    let id: Int
    @Domain var city: String
    @Domain var temperature: Double

    var title: String { city }
    var detail: String {
        temperature.formatted(.number.precision(.fractionLength(1))) + "°"
    }
}

// One state type per feature. @Domain members are interactor-only; every other member —
// stored or computed — is view-visible and diffed per member at commit.
@FeatureState
struct WeatherSearchState {
    @Domain var isSearching = false
    @Domain var errorMessage: String?

    var query: String = ""
    var results: IdentifiedArrayOf<WeatherResult> = []

    var statusText: String {
        if let errorMessage { errorMessage }
        else if isSearching { "Searching…" }
        else { "\(results.count) results" }
    }
}

enum WeatherSearchAction {
    case queryChanged(String)
}

@Interactor<WeatherSearchState, WeatherSearchAction>
struct WeatherSearchInteractor {
    let weatherClient: WeatherClient
    let clock: any Clock<Duration>

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .queryChanged(let query):
                // Update phase: synchronous mutations are visible immediately.
                state.query = query
                guard !query.isEmpty else {
                    state.results = []
                    state.isSearching = false
                    return
                }
                state.isSearching = true

                // Each `.queryChanged` dispatch replaces the previous in-flight task at this
                // `perform` call site — cancelling the pending sleep restarts the debounce window.
                effects.perform { [weatherClient, clock] effectState in
                    try await clock.sleep(for: .milliseconds(300))
                    do {
                        let results = try await weatherClient.search(query: query)
                        try effectState.modify { state in
                            state.isSearching = false
                            state.results = IdentifiedArray(uniqueElements: results)
                            state.errorMessage = nil
                        }
                    } catch {
                        try effectState.modify { state in
                            state.isSearching = false
                            state.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

import SwiftUI

struct WeatherSearchView: View {
    @State private var viewModel: ViewModel<WeatherSearchState, WeatherSearchAction>

    init(weatherClient: WeatherClient) {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: WeatherSearchState(),
                interactor: WeatherSearchInteractor(
                    weatherClient: weatherClient,
                    clock: ContinuousClock()
                )
            )
        )
    }

    var body: some View {
        // Row identity from the projection's ids; each row re-renders only when its own
        // visible output changes.
        List(viewModel.results.ids, id: \.self) { id in
            if let row = viewModel.results[id: id] {
                LabeledContent(row.title, value: row.detail)
            }
        }
        .searchable(
            text: Binding(
                get: { viewModel.query },
                set: { viewModel.sendViewEvent(.queryChanged($0)) }
            )
        )
        .overlay { Text(viewModel.statusText) }
    }
}
```

Things to notice:

- **One state type.** There is no handwritten ViewState struct and no reducer type —
  `@Domain` fences `isSearching`/`errorMessage` and the per-result internals off from views,
  and the visible computed properties (`statusText`, each row's `title`/`detail`) *are* the
  derived view output. `viewModel.isSearching` does not compile; `viewModel.statusText`
  invalidates its readers only when the derived string actually changes (per-member diff at
  commit — there is no state-equality strategy to configure).
- **One action case.** There is no `.searchResponse` — the effect mutates state directly via
  `effectState.modify`, and the same commit diff runs for that re-entry exactly as it does for
  synchronous mutations.
- **Nothing is `Sendable`.** `WeatherClient`, the state, and the action enum are plain
  types. The effect closure runs in the feature's isolation domain (the main actor under
  `ViewModel`), so captures never cross an isolation boundary.
- **Debounce is task replacement.** No debounce API: re-dispatching the same action replaces
  the in-flight task at that location; `clock.sleep` provides the quiet period. Inject
  `TestClock` in tests.

## Architecture

1. The view sends an action via `sendViewEvent(_:)`.
2. `ViewModel` runs the synchronous **update phase** immediately in its isolation domain:
   the interactor mutates domain state in place and may launch effects with `effects.perform`.
3. Every mutation runs the **commit funnel**: scope-transition detection (cancelling effects
   whose `When` scope departed), then the projection diff — the generated `_commit` compares
   old and new state and notifies exactly the view-visible members whose value or derived
   output changed.
4. Launched effects start synchronously in-domain, run up to their first suspension point, and
   later re-enter by mutating state directly with `effectState.modify` (or, optionally, by sending
   an action with `effectState.send`). Each re-entry runs the same commit funnel.
5. `EventTask.finish()` waits for the effects launched directly by the send to complete, and
   `cancel()` cancels them. Work started by a re-entrant `effectState.send` is an independent unit
   with its own task.

## State Modeling with Lattice

Lattice keeps the domain-logic / rendering-instructions split, but expresses it inside a
single `@FeatureState` type instead of two types joined by a reducer:

- `@Domain` members are the business-logic model for the feature — raw values (`Date`, IDs),
  workflow state, and external models when they are domain-aligned. They are visible to the
  interactor and to effects, and invisible to views (`viewModel.someDomainMember` does not
  compile).
- Every other member — stored or computed — is the view contract. Visible computed properties
  are derived view output: think formatted strings, visibility flags, and composed
  presentation values. They are diffed by output at commit, so views re-render only when the
  derived value actually changes.

### Keep Views Dumb

Views should render projected members and send actions. Formatting logic, complex branching,
and business rules belong in the interactor or in visible computed properties on the state.

- Why: it keeps business logic testable without SwiftUI and reduces debugging surface area.
- Rule: if a value needs formatting for display, derive it as a visible computed property on
  the state; keep the raw value in a `@Domain` member.

### Layer Boundaries and External Data

- Views: send actions and render projected members.
- Interactors: mutate state and connect to external systems (`APIClient`, `DBClient`, etc.)
  via plain (non-`Sendable`) dependencies.
- Visible computed properties: convert domain data to display language.
- Flow: view action -> interactor mutation/effect -> state commit -> projection diff -> render.

### Rows in lists

Store list elements as `@FeatureState` values in an `IdentifiedArrayOf` member and put each
row's rendering data in the element's visible computed properties. The commit diff is
identity-keyed: a change to one row fires only that row's changed members. See the Weather
Search example above and `ExampleProject/SearchExamplePackage` for the full pattern.

## Bindings

Use `@Bindable` with case-path actions; reads go through the projection, writes send actions:

```swift
@CasePathable
enum FormAction {
    case nameChanged(String)
}

@FeatureState
struct FormState {
    var name: String = ""
}

@Bindable var viewModel: ViewModel<FormState, FormAction>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

For `CasePathable` enum state, bindings can be scoped to case members:

```swift
$viewModel.detail.title.sending(\.detailTitleChanged, default: "")
```

Use `sending(_:default:)` when the view may access a binding while the state is in a different case.

## Effects

Launch async work imperatively with `effects.perform` during the synchronous update phase.
Effects re-enter by mutating state directly:

```swift
case .fetchData:
    state.isLoading = true
    effects.perform { [api] effectState in
        let data = try await api.fetch()
        try effectState.modify { state in
            state.isLoading = false
            state.data = data
        }
    }
```

- Streams are `for await` loops inside `perform`; there is no separate observe primitive.
- Sequential work is sequential `await`s inside one `perform` closure; concurrent work is
  multiple `perform` calls.
- Name a long-lived effect with `@EffectID var recording` and `effects.perform(id: recording)`
  to cancel or await it explicitly.

### Debounce by replacement

There is no debounce API. The first `perform` at a call site during an update **replaces**
that call site's in-flight task, so a leading `clock.sleep` *is* the debounce window:

```swift
case .queryChanged(let query):
    state.query = query                                  // immediate, synchronous
    effects.perform { [searchClient, clock] effectState in
        try await clock.sleep(for: .milliseconds(300))   // cancelled by the next keystroke
        let results = await searchClient.search(query)
        effectState.results = results
    }
```

## Composition

Scope child features with case paths or key paths:

```swift
parentInteractor.when(state: \.childState, action: \.child) {
    ChildInteractor()
}
```

If the parent's enum leaves the child's case (or the scoped optional becomes `nil`) while a
child effect is in flight, the child's tasks are cancelled and any straggling
`effectState.modify`/`effectState.send` is dropped silently — the
navigation-dismissed-mid-request contract.

## Scoped View Composition

`ViewModel.scope(state:action:)` projects a parent view model onto a child slice of the view
projection and a child action space, so child views depend only on their own
`ScopedViewModel<ChildState, ChildAction>` instead of the parent's `ViewModel` type.

```swift
@CasePathable
enum DashboardAction {
    case header(HeaderAction)
    case footer(FooterAction)
}

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
        Button("Refresh") { model.sendViewEvent(.refreshTapped) }
    }
}
```

`ScopedViewModel` is a stateless value type: it owns no state, effects, or lifecycle, so it is
cheap to recreate on every render. Reads go through the child's projection, so child views
observe fine-grained; sends embed into the parent action and return the parent's `EventTask`.

- Read members through the scope (`model.title`, `model.badge.count`) for fine-grained
  observation.
- Create scopes inline in `body`; do not store them in `@State` or long-lived properties (a
  scope retains its parent view model).
- Overloads: case-path action embedding (shown above), a closure-based `scope(state:action:)`
  for non-`CasePathable` actions, and a read-only `scope(state:)` whose action type is `Never`.
- Scopes compose: `ScopedViewModel.scope(state:action:)` projects a grandchild slice through
  the parent.
- Two-way bindings: `model.binding(\.name, sending: \.nameChanged)`.

### Enum-case scoping

When state is a `@FeatureState` `@CasePathable` enum, scope onto the active case's payload via
the generated case accessors. `scopeIfActive(state:action:)` returns `nil` when the case is
not active, which doubles as the branch condition:

```swift
if let success = viewModel.scopeIfActive(state: \.success, action: \.success) {
    SuccessView(model: success)
} else {
    LoadingView()
}
```

The trapping `scope(state:action:)` variant is sugar for contexts that have already
established the case is active (it `fatalError`s otherwise). Case-accessor projection reads
(`if let detail = viewModel.detail { … }`) cover read-only branching.

If the case departs while a child effect is in flight, the runtime cancels the child's tasks
and drops straggling writes — no hand-rolled staleness guards needed.

See `ExampleProject/ScopedCompositionExamplePackage` for a runnable demo of both styles, and
`specs/scoped-view-composition.md` / `specs/enum-case-scoping.md` for design details.

## Testing with `TestViewModel`

Use `TestViewModel` for snapshot-diff feature tests: every state change — synchronous
mutations from `send` and asynchronous re-entries from `effectState.modify` — is asserted as a
diff against the previous state.

```swift
let clock = TestClock()
let model = TestViewModel(
    initialDomainState: SearchState(),
    interactor: SearchInteractor(searchClient: SearchClientStub(), clock: clock)
)

// Update phase: synchronous mutations asserted immediately.
await model.send(.queryChanged("lattice")) {
    $0.query = "lattice"
    $0.isLoading = true
}

// Cross the debounce window, then assert the effect's `modify` re-entry.
await clock.advance(by: .milliseconds(300))

await model.expect {
    $0.isLoading = false
    $0.results = ["Lattice"]
}
```

`TestViewModel` semantics:

- `send(_:changes:)` asserts the synchronous update-phase mutation and returns a
  `TestEventTask` over the effects that send launched.
- `expect(changes:)` asserts the next state change committed by an effect's
  `effectState.modify`, waiting up to a timeout for one to arrive.
- `receive(_:changes:)` asserts an action re-entered via `effectState.send` (rare; most
  effects use `modify` and are asserted with `expect`). Case-path matching:
  `receive(\.someCase) { … }`.
- `exhaustivity` is on by default: unasserted commits fail the test. `skipPendingCommits()`
  is the explicit escape hatch.
- `dismount()` tears the feature down, cancelling in-flight effects, and fails on unasserted
  commits; `finish()` waits for effects to complete naturally.
- View output is asserted by reading the projection: `#expect(model.projection.statusText == "1 results")`.
- Nothing in a test needs `Sendable`: stub clients can be plain classes.

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

Run focused effect and core suites:

```bash
swift test --filter EffectsHandleTests
swift test --filter EffectCancellationTests
swift test --filter EffectIDTests
swift test --filter ScopedEffectsTests
swift test --filter InteractorGraphPathTests
```

Run testing-infrastructure and state suites:

```bash
swift test --filter TestViewModel
swift test --filter FeatureStateRuntimeTests
```

## Development

Build all targets:

```bash
swift build
```

Formatting is handled by the pre-push hook with `swift-format`. Do not run `swift-format` manually.

The macro binary is never checked in: SwiftPM/Xcode consumers build the `LatticeMacros` target
from source, and CocoaPods consumers generate `Macros/LatticeMacros` at `pod install` via the
podspec `prepare_command` (`scripts/rebuild-macro.sh`). Set `SKIP_LATTICE_MACRO_BUILD=1` or
`SKIP_LATTICE_MACRO_BUILD=true` to skip that build when needed.

Sync local Codex and Claude skill folders:

```bash
scripts/sync-skills.sh
```

## Project Layout

- `Sources/Lattice`: runtime library (interactors, effects, feature state, view model, testing helpers).
- `Sources/LatticeMacros`: macro implementations.
- `ExampleProject/`: sample app and package-based examples.
- `Tests/`: library and macro tests.
