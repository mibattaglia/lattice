# Lattice

Lattice is a Swift 6 library for building features with MVVM + unidirectional data flow.
It uses native Swift concurrency and supports iOS 17+, macOS 14+, and watchOS 10+. `ActorModel` and `TestModel` need iOS 26, macOS 26 or watchOS 26.

## Core Features

- Unidirectional flow: views send actions, the interactor mutates the feature's one state, and views re-render from the members they read.
- One state per feature: `@FeatureState` generates the `ViewState` projection views read through; `@Domain` hides a member from views at compile time and keeps it observation-tracked.
- Feature-based API: `ViewModel` is parameterized by a single feature type (`ViewModel<F>`).
- Effects: `interact(state:action:effects:)` mutates the state synchronously and queues asynchronous work with `effects.perform`. An effect delivers its result with `effects.modify`, so there is no response action to send and handle.
- Automatic cancellation: handling an action case again cancels the anonymous effects that case started before; `@EffectID` names an effect that is never auto-cancelled, for replacement by key, `effects.cancel(_:)` and `effects.isRunning(_:)`.
- A nonisolated core in isolated shells: `ViewModel` (main actor), `ActorModel` (an actor of its own), `TestModel` and `TestViewModel` run the same core, so nothing in the feature layer has to be `Sendable`.
- Debouncing and timers: an effect sleeps with `try await clock.sleep(for:)` on an injected clock, and handling its action case again cancels it while it sleeps. Tests move time with `EffectClock` and the test shell's `advance(_:by:)`.
- Interactor composition: `Interactors.When`, `when(state:action:child:)`, `Merge`, and `MergeMany`.
- View composition: `scope(state:action:)` and `ScopedViewModel` project fine-grained child states, optional children, collections, and enum-case payloads (`scopeIfActive`).
- SwiftUI integration: `@Bindable`, dynamic member lookup over the `ViewState` projection, and `sendViewEvent(_:)`, which returns the `Task<Void, Never>?` of the effects it started.
- Step-wise testing: `TestModel` and `TestViewModel` assert every commit with `send`, `receive`, `expect` and `finish`, exhaustively by default.

## Installation

Lattice requires Swift 6.2 tools or later.

Add package dependency:

```swift
dependencies: [
    .package(url: "https://github.com/mibattaglia/lattice", .upToNextMinor(from: "0.4.0"))
]
```

Add product dependency:

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "Lattice", package: "lattice")]
)
```

### CocoaPods

`Lattice.podspec` ships the runtime library only. It excludes `Sources/Lattice/Testing`, so `TestModel` and `TestViewModel` come with the Swift package only. The pod builds the macro plugin with the local toolchain during `pod install` (`scripts/rebuild-macro.sh`) and loads it with `-load-plugin-executable`, and it compiles Lattice with `-enable-upcoming-feature NonisolatedNonsendingByDefault`, as `Package.swift` does.

## Quick Start

### 1. State and actions

```swift
import Foundation
import Lattice

@FeatureState
struct CounterState: Equatable {
    var count = 0
}

enum CounterAction {
    case increment
    case decrement
    case load
}
```

`@FeatureState` tracks each stored member for observation and generates `CounterState.ViewState`, the projection views read through. A file that declares a `@FeatureState` type needs `Observation` in scope; importing `Foundation` or `SwiftUI` provides it. Neither type has to be declared `Sendable`. Make `Action` an enum: automatic cancellation keys on its cases.

### 2. Interactor and effects

```swift
import Lattice

protocol CounterClient {
    nonisolated(nonsending) func fetchCount() async -> Int
}

@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    let counterClient: CounterClient

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .increment:
                state.count += 1
            case .decrement:
                state.count -= 1
            case .load:
                effects.perform {
                    let count = await counterClient.fetchCount()
                    try effects.modify { $0.count = count }
                }
            }
        }
    }
}
```

- `Interact { state, action, effects in … }` handles an action synchronously and returns nothing. When the handler performs no effects, drop the `effects` parameter: `Interact { state, action in … }`.
- `effects.perform { … }` only queues the effect. It starts after the closure returns, and it runs until its first suspension before `sendViewEvent(_:)` returns. It runs on the main actor under `ViewModel` and resumes there after every suspension.
- The effect delivers its result with `effects.modify`: one commit, with no response action.
- Sending `.load` again cancels the `.load` effect that is still running; see [Effects and Cancellation](#effects-and-cancellation).
- `CounterClient` is a plain protocol, not `Sendable`. Its async method is `nonisolated(nonsending)`, so the effect calls it on the main actor too; see [Concurrency settings](#concurrency-settings).

### 3. Presentation members

There is no separate view-state type. Display values are computed members of the state, and members that views must not read are marked `@Domain`:

```swift
@FeatureState
struct CounterState: Equatable {
    @Domain var count = 0
    var countText: String { String(count) }
}
```

`count` stays observation-tracked, so a view that reads `countText` re-renders when `count` changes, but `CounterState.ViewState` does not expose `count`.

### 4. ViewModel and SwiftUI

```swift
import Lattice
import SwiftUI

struct CounterView: View {
    @State private var viewModel = ViewModel(
        initialState: CounterState(),
        feature: Feature(interactor: CounterInteractor(counterClient: LiveCounterClient()))
    )

    var body: some View {
        List {
            Text(viewModel.countText)
            Button("-") { viewModel.sendViewEvent(.decrement) }
            Button("+") { viewModel.sendViewEvent(.increment) }
        }
        .refreshable { await viewModel.sendViewEvent(.load)?.value }
        .task {
            let load = viewModel.sendViewEvent(.load)
            await withTaskCancellationHandler {
                await load?.value
            } onCancel: {
                load?.cancel()
            }
        }
    }
}
```

`LiveCounterClient` stands for your production `CounterClient`.

- `sendViewEvent(_:)` is synchronous. When it returns, the interactor has run, the state is committed and every effect the action started has run until its first suspension.
- It returns a discardable `Task<Void, Never>?`: `nil` when the action started no effect, otherwise the task for exactly the effects it started, not for the effects those start in turn. Cancelling the task cancels them.
- `.refreshable` awaits the task directly, because the load ends by itself.
- Awaiting `Task.value` does not cancel the task, so `.task` forwards its own cancellation: the load stops when the view goes away. Start long-lived effects, such as tickers and streams, the same way.

`viewModel.countText` reads through `CounterState.ViewState`. Reading a `@Domain` member does not compile:

```text
viewModel.count  // error: 'count' is unavailable: 'count' is @Domain state and is not visible to views
```

`Feature(interactor:)` compares states with `==` when the state is `Equatable`. Pass `areStatesEqual:` when the state is not `Equatable` or when a custom comparison is the right boundary:

```swift
let feature = Feature(
    interactor: CounterInteractor(counterClient: LiveCounterClient()),
    areStatesEqual: { lhs, rhs in lhs.count == rhs.count }
)
```

## Architecture

A feature runs in a nonisolated `Core`, which holds the state, the interactor, the effects it queued and the effects that are running. An isolated shell hosts the core, and the core is only ever touched on that shell's isolation. So it needs no locks, and nothing in the feature layer has to be `Sendable`: not the state, the actions, the interactors, their dependencies or the effect closures.

| Shell | Kind | Runs the core and its effects on | Availability |
|---|---|---|---|
| `ViewModel` | `@MainActor` class, for SwiftUI | the main actor | iOS 17, macOS 14, watchOS 10 |
| `ActorModel` | actor, for features off the main actor | its own serial executor | iOS 26, macOS 26, watchOS 26 |
| `TestModel` | actor, the primary test shell | its own serial executor | iOS 26, macOS 26, watchOS 26 |
| `TestViewModel` | `@MainActor` class, for main-actor-isolated interactors | the main actor | iOS 17, macOS 14, watchOS 10 |

The production path:

1. A view sends an action through `ViewModel.sendViewEvent(_:)`, which hands it to the view model's `Core` on the main actor.
2. The core runs the interactor on a working copy of the state. Each member change notifies only that member's observers, and every effect the interactor performs is only queued.
3. The core commits the working copy. A content-equal wholesale replacement (per `areStatesEqual`) is dropped, and only a new root identity re-renders every reader; otherwise views re-render only for the members they read that changed. Then the core cancels the anonymous effects previously started for the same action case, at the root and at each child case a `When` routes the action into; effects with an `@EffectID` are never auto-cancelled.
4. The core starts the queued effects in order on the main actor. Each runs until its first suspension before `sendViewEvent(_:)` returns, which hands back the task for those effects.
5. Effects resume on the main actor after every suspension. They deliver results with `effects.modify`, which commits by the same rules, and send actions only to start effects, run interactor logic or cancel by action case.

Views read members (`viewModel.title`, `viewModel.badge.count`) for fine-grained observation. `viewModel.viewState` is the coarse read of the whole projection: it re-renders on a wholesale replacement or an enum case change, while members read off it stay fine-grained.

### ActorModel

`ActorModel` runs a feature on a serial executor of its own, off the main actor, for features that are not bound to a view:

```swift
@available(iOS 26, macOS 26, watchOS 26, *)
func syncInTheBackground(client: sending SyncClient) async -> Int {
    let model = await ActorModel(
        initialState: SyncState(),
        feature: Feature(interactor: SyncInteractor(client: client))
    )
    await model.send(.sync)?.value
    return await model.state.pendingCount  // reading from outside needs `SyncState: Sendable`
}
```

- Its `init` is `async`, and `send(_:)` is the counterpart of `sendViewEvent(_:)`, with the same synchronous processing and the same returned task.
- `await model.state` crosses the actor, so it needs `State: Sendable`.
- It is not `Observable`, and it has no `ViewState` reads, bindings or scopes.
- Teardown is asynchronous: released off its executor, its `isolated deinit` runs later, as a job on that executor, and cancels the effects then.
- A helper that receives a non-`Sendable` dependency and builds the model from it takes the parameter as `sending`, as above.

### Concurrency settings

- The `Lattice` target enables the upcoming feature `NonisolatedNonsendingByDefault`. An effect closure (`EffectOperation`) is `nonisolated(nonsending)` whatever your settings, so it runs on the shell's isolation, resumes there after every suspension and may capture non-`Sendable` dependencies.
- Your own async functions follow your module's setting. In a module without `NonisolatedNonsendingByDefault`, a plain `func fetch() async` is `@concurrent`, and calling it from an effect on a captured non-`Sendable` dependency fails with `sending 'self.client' risks causing data races`. Mark such methods `nonisolated(nonsending)`, as `CounterClient` does, or enable the feature in your module with `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`.
- Effects run on the shell. CPU-bound work in an effect runs on the main actor under `ViewModel`; move it behind a `@concurrent` function or a dependency with its own executor.
- An interactor formed in main-actor-isolated code, such as a module with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` or a `@MainActor` context, is a main-actor value. Handing it to `ActorModel` or `TestModel` is a compile error, so such features use `ViewModel` and `TestViewModel`.
- `Action` should be an enum. Automatic cancellation keys on the action's case; for a non-enum action every send cancels every anonymous effect.

## State Modeling with Lattice

Each feature has one state type, and its interactor and the interactor's effects are the only code that mutates it. `@FeatureState` generates a `ViewState` projection of that state, and views read the state only through it. That boundary keeps tests expressive and decoupled from SwiftUI, keeps debugging simple, and keeps business data out of the rendering layer.

- Visible members: rendering instructions. Think strings, colors, visibility flags, and composed presentation models, usually computed from the members below.
- `@Domain` members: the business-logic model. Raw values (`Date`, IDs), workflow state, and external models when they are domain-aligned. They stay observation-tracked, so computed members that read them re-render when they change.
- The interactor: the only mutator. It applies actions synchronously, and its effects connect to external systems and write their results with `effects.modify`.

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
- Interactors: mutate the state and connect to external systems (`APIClient`, `DBClient`, etc.) via dependencies, from their effects.
- Computed members: convert domain data to display language.
- Flow: view action -> interactor mutation and effects -> state commit -> re-render of the views that read a changed member.

For BFF/server-driven or inert UI features, leave every member visible: the state already is the render model.

### Counter + API Modeling Example

```swift
import Foundation
import Lattice

struct CounterAPIModel: Codable, Equatable {
    let count: Int
    let updatedAt: Date
}

@FeatureState
struct CounterState: Equatable {
    var title = "Counter"
    var isRefreshing = false
    var errorMessage: String?
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

enum CounterAction {
    case task
    case cancelRefresh
}

protocol CounterClient {
    nonisolated(nonsending) func fetch() async throws -> CounterAPIModel
}

@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    @EffectID var refresh
    let counterClient: CounterClient

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .task:
                state.isRefreshing = true
                effects.perform(id: refresh) {
                    defer { try? effects.modify { $0.isRefreshing = false } }  // also runs when cancelled
                    do {
                        let model = try await counterClient.fetch()
                        try effects.modify {
                            $0.count = model.count
                            $0.lastUpdatedAt = model.updatedAt
                        }
                    } catch {
                        try Task.checkCancellation()  // a cancelled refresh writes no error
                        try effects.modify { $0.errorMessage = "\(error)" }
                    }
                }
            case .cancelRefresh:
                effects.cancel(refresh)
            }
        }
    }
}
```

- There is no response case. The effect writes its result with one `effects.modify`, which is one commit and one test entry, however many members it sets.
- `@EffectID var refresh` names the effect. Its key is the declaration site, so it lives on the interactor, not in the state. `perform(id: refresh)` replaces a running refresh, and `.cancelRefresh` stops it with `effects.cancel(refresh)`: automatic cancellation reaches only a re-sent `.task`, and it never cancels an identified effect. `effects.isRunning(refresh)` tells whether the refresh runs.
- The `defer` runs on every path, cancelled or not, so the flag is always cleared. But a run that is replaced or cancelled runs its `defer` after its replacement has started: a second `.task` replaces the first refresh, and the first refresh's `defer` sets `isRefreshing` to `false` while the second is still running.
- The `catch` checks for cancellation before it writes an error. A cancelled effect's `modify` is still committed, and cancellation can arrive as another error, such as `URLError(.cancelled)`. `try Task.checkCancellation()` is mandatory after `try?` or `catch`, and it belongs right before any result that a newer action made stale.
- An error that leaves a live effect is reported as `Effect threw: <error>`: a test failure, and a runtime warning in an app. Errors thrown once the effect's task is cancelled are not reported.

`Text(viewModel.lastUpdatedText)` re-renders when `lastUpdatedAt` changes, while `viewModel.lastUpdatedAt` does not compile. Computed members are recomputed on each read; a derived value that is expensive to compute can be a visible stored member that the interactor keeps in sync.

### Known Issue: One `@FeatureState` Enum per File

A known Swift 6.4 compiler bug can crash the compiler (a segfault in `TypeCheckPrimaryFileRequest`) when a source file holds a `@FeatureState` enum together with other macro-annotated declarations: other `@FeatureState` types, `@CasePathable` enums, `@Observable` classes, `@Interactor` types, and so on. Declare each `@FeatureState` enum, `@CasePathable` or not, in its own file with no other macro-annotated declaration. Files whose `@FeatureState` types are all structs are not affected. This is a temporary layout rule that works around the compiler bug, not a design choice; see [`specs/feature-state.md`](specs/feature-state.md#limitations).

## Bindings

Use `@Bindable` with case-path actions:

```swift
@CasePathable
enum FormAction {
    case nameChanged(String)
}

@FeatureState
struct FormState: Equatable {
    var name = ""
}

@Bindable var viewModel: ViewModel<Feature<FormAction, FormState>>

TextField("Name", text: $viewModel.name.sending(\.nameChanged))
```

Binding key paths are rooted at `FormState.ViewState`, so `$viewModel.member` rejects a `@Domain` member at compile time. A write sends the action and discards the task `sendViewEvent(_:)` returns.

For a `@CasePathable` enum state, bindings reach the members of a case payload through the generated `ViewState` mirror. In the Search example, whose state has `case results(ResultState)`:

```swift
$viewModel.results.query.sending(\.search.query)
$viewModel.results.query.sending(\.search.query, default: "")
```

`sending(_:)` traps if the state is in a different case. Use `sending(_:default:)` when the view may access a binding while the state is in a different case.

## Effects and Cancellation

The interactor receives an `Effects<State, Action>` handle. [`specs/effects-and-isolation.md`](specs/effects-and-isolation.md) describes it in full; these are the rules that matter when you write a feature.

| Member | Call it from | What it does |
|---|---|---|
| `perform(id:_:)` | `interact` | Queues an effect. It is `noasync`, so inside an effect it does not compile: `'perform' is unavailable from asynchronous contexts`. From a synchronous closure inside an effect, such as a `modify` body, it compiles but is reported and dropped. |
| `modify(_:)` | an effect | Commits a change to the state: one commit and one test entry, however many members the body touches. |
| `state` | an effect | Reads the committed state. It is get-only; changes go through `modify`. |
| `send(_:)` | an effect | Sends an action, processed at once and depth-first, and returns the task for the effects that action started. |
| `cancel(_:)`, `isRunning(_:)` | anywhere | Cancels or queries an `@EffectID` effect in the handle's scope. |

- Effects start after `interact` returns, in `perform` order. Each runs its synchronous preamble, everything up to its first suspension, before the send returns, and resumes on the shell after every suspension.
- Results are modifications. An effect sends an action only for what a modification cannot do: start new effects, run interactor logic that a parent, a `Merge` sibling or a `When` reacts to, or cancel by action case.
- There is no action queue: `effects.send` during `interact` is reported and dropped. To follow an action with another one, send it from an effect: `effects.perform { try effects.send(.next) }`.
- Several sequential steps are one effect doing them in order, and concurrent work is several `perform` calls. A stream is a `for await` loop inside one effect: `for await value in stream { try effects.modify { $0.apply(value) } }`.

### Automatic cancellation

Handling an action case again cancels the anonymous effects, the ones performed without an `id`, that the case started before. This happens at the root and at each child case a `When` routes the action into:

| Running | Then sent | Cancelled |
|---|---|---|
| `.search("a")`'s effect | `.search("b")` | the `"a"` effect |
| `.search("a")`'s effect | `.other` | nothing |
| `.child(.start)`'s child effect | `.child(.other)` | nothing |
| `.child(.start)`'s child effect | `.child(.start)` | the previous child effect |

An action that the interactor ignores still cancels: it leaves the case's earlier effects cancelled and starts none. A guard on a running flag kept in state does not avoid this, and a `defer` that clears the flag does not fix it. There are two remedies:

- Identify the effect with `@EffectID` and `perform(id:)`. An identified effect is never auto-cancelled, so it survives an action that is ignored; the next `perform` of its key replaces it, and `effects.cancel(_:)` stops it from any case. For one effect per row, scope the key, as below.
- When the view owns the effect, drop the guard. Re-sending the action then replaces the running effect, so there is never more than one, and the view's `.task` cancels it.

```swift
@Interactor<DownloadsState, DownloadsAction>
struct DownloadsInteractor {
    @EffectID var download
    let client: DownloadClient

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .start(let id):
                effects.perform(id: $download.scoped(id)) {  // one effect per row
                    try await client.download(id)
                    try effects.modify { _ = $0.finished.insert(id) }
                }
            case .cancel(let id):
                effects.cancel($download.scoped(id))
            }
        }
    }
}
```

Build per-row keys from one declaration with `scoped(_:)`. Only a handle in the same scope can cancel or query a key; a parent and a view cannot.

### Cancellation is cooperative

Cancelling an effect cancels its task, and the effect stops at its next cancellation-aware suspension (`Task.sleep`, `clock.sleep`, cancellable APIs). Until then it keeps running, and its modifications are still committed. When a sleep returns or a dependency answers, the effect hops back to the shell, and a cancel that lands first cannot stop the code the effect runs before its next cancellation-aware suspension: a tick loop gets at most one extra tick, and a load can commit a result that was due.

When a late result would be wrong, call `try Task.checkCancellation()` right before the `modify` that delivers it. On the shell's serial isolation nothing can land between the check and the commit. The check is mandatory after `try?` or `catch`, which turn a cancellation into a value:

```swift
case .queryChanged(let query):
    state.query = query
    effects.perform {
        let results = (try? await searchClient.search(query)) ?? []
        try Task.checkCancellation()  // a newer query cancelled this search: its results are stale
        try effects.modify { $0.results = results }
    }
```

It is not needed when the only suspension is a sleep that throws on cancel and every run writes the same guarded value.

### Errors

- An effect's operation is `async throws`. A `CancellationError`, or any error thrown once the effect's task is cancelled, is not reported.
- The error of a live effect is reported as an issue, `Effect threw: <error>`. That fails the test under Swift Testing and XCTest, and it is a runtime warning in an app.
- Catch the errors you expect and turn them into state. A `catch` that writes an error checks for cancellation first, with `try Task.checkCancellation()` or `guard !Task.isCancelled`, not with `error is CancellationError`. Cleanup goes in a `defer`, which runs on every path.

### The task `sendViewEvent(_:)` returns

- It is `nil` when the action started no effect, and otherwise the task for exactly the effects the action started. It does not wait for effects started by actions those effects send.
- Cancelling it cancels those effects: synchronously on OS 26, and before OS 26 once that task starts.
- Its `isCancelled` reflects only cancelling this task. Automatic cancellation, `cancel(_:)` and replacement cancel the effects' own tasks, and this task finishes once they have unwound.
- `await task?.value` is not cancellation-aware: cancelling the waiting task neither ends the wait nor cancels the effects. Await only effects that end by themselves, as `.refreshable` does, and forward cancellation from a `.task`, as in the [Quick Start](#4-viewmodel-and-swiftui).

### Teardown

Every shell's `isolated deinit` cancels its effects. A `ViewModel` released on the main actor does it inline, before the release returns; `ActorModel` and `TestModel` do it later, as a job on their executor. After that, `effects.send` and `effects.modify` throw `CancellationError` without reporting an issue, so an effect that writes with `try effects.modify` ends.

## Debouncing

A debounce is a sleep at the top of the effect. The action still changes the state at once, and handling the action case again cancels the previous effect while it sleeps, so a burst of edits ends in one search, a full 300 ms after the last edit:

```swift
@Interactor<SearchState, SearchAction>
struct SearchInteractor<C: Clock<Duration>> {
    let searchClient: SearchClient
    let clock: C

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .queryChanged(let query):
                state.query = query
                effects.perform {
                    try await clock.sleep(for: .milliseconds(300))  // the next edit cancels this sleep
                    let results = (try? await searchClient.search(query)) ?? []
                    try Task.checkCancellation()  // a newer query cancelled this search: its results are stale
                    try effects.modify { $0.results = results }
                }
            }
        }
    }
}

extension SearchInteractor where C == ContinuousClock {
    init(searchClient: SearchClient) {
        self.init(searchClient: searchClient, clock: ContinuousClock())
    }
}
```

- Coalescing is automatic cancellation, per action case: another case leaves the sleeping search alone, and a `.queryChanged` the interactor ignores still cancels it.
- A debounced effect that must survive an action the interactor ignores is identified: `perform(id:)` replaces it only with the next effect of its key.
- Write `try await clock.sleep(for:)` in a file that imports Lattice. That overload is Lattice's: it starts on the shell's isolation, which is what lets a test's `EffectClock` see the sleep as soon as `send` returns. See [Time](#time).

### Timers and clocks

A timer is a `while true` loop around a throwing sleep, with one modification per tick. An interactor that waits takes its clock as a generic parameter, and a `ContinuousClock` initializer keeps the app's call sites short:

```swift
@Interactor<TickerState, TickerAction>
struct TickerInteractor<C: Clock> {
    private let clock: C
    private let interval: C.Duration

    init(clock: C, interval: C.Duration) {
        self.clock = clock
        self.interval = interval
    }

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .startTicking:
                // Sending `.startTicking` again auto-cancels the running ticker.
                effects.perform {
                    while true {  // ends when cancelled: the sleep throws
                        try await clock.sleep(for: interval)
                        try effects.modify(tick)
                    }
                }
            }
        }
    }

    private func tick(_ state: inout TickerState) {
        state.ticks += 1
    }
}

extension TickerInteractor where C == ContinuousClock {
    init(interval: Duration = .seconds(1)) {
        self.init(clock: ContinuousClock(), interval: interval)
    }
}
```

- Write `try await clock.sleep(for:)`, never `try?`. Both `ContinuousClock` and test clocks throw at once after a cancel, so a `try?` loop spins, committing ticks, until the model is deallocated.
- The view starts the ticker from `.task` and forwards its cancellation, so the ticker stops with the view.
- Tests pass an `EffectClock`; see [Time](#time).

## Composition

`body` is an `InteractorBuilder`:

| In `body` | Builds |
|---|---|
| several children | `Interactors.Merge`: each child runs in order against the same state, with the same `Effects` handle |
| a `for` loop | `Interactors.MergeMany`; `Interactors.MergeMany(interactors:)` also takes an array directly |
| `if`/`else`, `switch` | `Interactors.Conditional`: only the chosen branch runs |
| `if` without `else` | an erased `AnyInteractor`, `EmptyInteractor` when false |

Two children that perform for the same action both run, and handling that action again cancels both. To store or pass a composed interactor as one value, erase it with `eraseToAnyInteractor()`, which has no constraint; `Feature(interactor:)` erases for you.

Scope a child feature to part of the parent's state and to a case of the parent's action with `Interactors.When`, or with the `when(state:action:child:)` modifier:

```swift
@Interactor<ParentState, ParentAction>
struct ParentInteractor {
    var body: some InteractorOf<Self> {
        Interactors.When(state: \.child, action: \.child) {
            ChildInteractor()
        }
        Interact { state, action in
            switch action {
            case .reset:
                state.child = ChildState()
            case .child, .sibling:
                break
            }
        }
        .when(state: \.sibling, action: \.sibling) {  // `Merge(When, self)`: the child runs first
            ChildInteractor()
        }
    }
}
```

- The state is a `WritableKeyPath` into a struct, or a `CaseKeyPath` into a `@CasePathable` enum state, such as `Interactors.When(state: \.loaded, action: \.loaded)`. The action is a `CaseKeyPath` into a `@CasePathable` action.
- The child gets an `Effects` handle of its own. Its sends are embedded into parent actions, and its modifications are written back into the parent state as one parent commit.
- Automatic cancellation is per child case: `.child(.other)` leaves the effects of `.child(.start)` running, and sending `.child(.start)` again cancels them. Two `When`s over the same child type, like the two above, keep independent `@EffectID` effects.
- With a case path, while the case is not active, the child's actions are ignored and none of its effects is cancelled. A case-scoped child whose case went away changes nothing: its effects' sends and modifications are reported and dropped. If the case becomes active again, those effects read and write the new payload.

## Scoped View Composition

`ViewModel.scope(state:action:)` projects a parent view model onto a child `@FeatureState` member and a child action space, so child views depend only on their own `ScopedViewModel<ChildState, ChildAction>` instead of the parent's `ViewModel` type.

```swift
@CasePathable
enum DashboardAction {
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

`ScopedViewModel` is a stateless value type: it owns no state, effects, or lifecycle, so it is cheap to recreate on every render. Reads walk the parent's live `@FeatureState` getter chain through `ChildState.ViewState`, so child views observe fine-grained and the child's `@Domain` members stay hidden. Sends embed into the parent action and return the parent's `Task<Void, Never>?`, so `await model.sendViewEvent(.refreshTapped)?.value` waits for the effects that send started.

- Read members through the scope (`model.title`, `model.badge.count`) for fine-grained observation. Reading the whole `model.viewState` value is coarse: it re-renders only when the child is replaced (or, for an enum child, changes case).
- Create scopes inline in `body`; do not store them in `@State` or long-lived properties (a scope retains its parent view model).
- Optional children: `scope(state: \.detail, action: \.detail)` returns `nil` while `detail` is `nil`.
- Collections: over an `Array` or `IdentifiedArrayOf` of `Identifiable` child states, `scope(state: \.rows, action: \.row)` returns one `Identifiable` scope per element, ready for `ForEach`. The action case carries the element id (`case row(RowState.ID, RowAction)`). An `IdentifiedArrayOf` finds each element in O(1), an `Array` in O(n).
- Overloads: case-path action embedding (shown above), a closure-based `scope(state:action:)` for non-`CasePathable` actions, and a read-only `scope(state:)` whose action type is `Never`.
- Scopes compose: `ScopedViewModel.scope(state:action:)` projects a grandchild through the parent.
- Two-way bindings: `model.binding(\.name, sending: \.nameChanged)`. A write sends the action and discards the task.

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

## Testing

`TestModel` and `TestViewModel` run the feature's `Core` exactly as production does. They record every commit made outside the action under test, whether an action an effect sent or a modification an effect made, until the test describes it. [`specs/testing-infrastructure.md`](specs/testing-infrastructure.md) has the full contract.

| | `TestModel` | `TestViewModel` |
|---|---|---|
| Kind | actor on its own executor; the primary test shell | `@MainActor` class, for main-actor-isolated interactors |
| Availability | iOS 26, macOS 26, watchOS 26 | iOS 17, macOS 14, watchOS 10 |
| `init` and `send` | `async`: `await TestModel(…)`, `await model.send(…)` | synchronous |
| Exhaustivity | `await model.setExhaustivity(_:)` | a settable `exhaustivity` property |
| Timeout | the `init` parameter | the `init` parameter, or the settable `timeout` property |

### Writing a `TestModel` test

This test drives the [Counter + API example](#counter--api-modeling-example):

```swift
import Foundation
import Lattice
import Testing

final class StubCounterClient: CounterClient {
    static let date = Date(timeIntervalSince1970: 1_000)
    let count: Int

    init(count: Int) {
        self.count = count
    }

    nonisolated(nonsending) func fetch() async throws -> CounterAPIModel {
        await Task.yield()  // suspends, so the result commits after `send` returns
        return CounterAPIModel(count: count, updatedAt: Self.date)
    }
}

@Suite
struct CounterTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func hydrates() async {
        let model = await TestModel(
            initialState: CounterState(),
            feature: Feature(interactor: CounterInteractor(counterClient: StubCounterClient(count: 4)))
        )
        await model.send(.task) { $0.isRefreshing = true }?.value
        await model.expect {  // the effect wrote its result, then its `defer` cleared the flag
            $0.count = 4
            $0.lastUpdatedAt = StubCounterClient.date
            $0.isRefreshing = false
        }
        await model.finish()
    }
}
```

- Put `@available(iOS 26, macOS 26, watchOS 26, *)` on each `@Test`, and on each helper that names `TestModel`, not on the `@Suite`.
- Keep the suite nonisolated, without `@MainActor`. Form the interactor, its dependencies and the closures you pass (`assert`, a `receive` predicate) in nonisolated code, such as file scope in the test target. A main-actor interactor, or a closure formed in a `@MainActor` test, is a compile error; such features use `TestViewModel`.
- Test doubles are plain classes, and nothing a test hands the model needs `Sendable`. Reading `await model.state` is the exception: it crosses the actor, so it needs `State: Sendable`. Internal value types are inferred `Sendable`; the `assert` closures work with any state.
- The stub suspends before it answers, so the effect's modifications commit after `send` returns and `expect` describes them. An effect that never suspends finishes inside `send`, and `send`'s `assert` describes its modifications too, up to the first action it sends.

### The assertions

- `send(_:assert:)` first handles what is pending: reported when exhaustive, skipped when `.off`. It then sends the action and asserts the action's change plus the modifications its effects committed before they first suspended, up to the first action they sent. It returns the `Task<Void, Never>?` for the effects the action started.
- `receive` waits for an action an effect sent. It has three forms: `receive(.saved(id: 7))` for an `Equatable` action, `receive({ … })` with a predicate, and `receive(\.saved)` with a case key path into a `@CasePathable` action. Its `assert` describes the action and the modifications around it. It waits until a matching action is pending, failing at once when no effect is left in flight, or for its `timeout:`, by default the model's (1 second unless `init` sets another).
- `expect { … }` asserts the modifications effects made, folding every pending modification up to the next action into one assertion. It is synchronous and does not wait: await the effect first (`await model.send(…)?.value`), `advance` the `EffectClock` it sleeps on, receive an action it sends, or wait for a signal it gives. It can pass vacuously: before an effect has run, `expect { _ in }` compares an unchanged state.
- `finish()` waits until no effect is in flight, then reports, or skips when `.off`, whatever is still pending. End every exhaustive test with it.
- `skipReceived(strict:)` advances the model past every pending action and modification without asserting them. `skipInFlightEffects(strict:)` cancels every in-flight effect and waits for them; what they commit while they unwind stays pending.
- `model.state` is the state the test last asserted, `@Domain` members included. Pending commits are not in it.

### Exhaustivity

`Exhaustivity.on`, the default, requires every commit to be described: actions with `receive`, modifications with `expect`, or folded into the enclosing `send` or `receive`. What is still pending is reported at the next `send`, as leading actions at the next `expect` (which folds the pending modifications, so an undescribed one fails as that `expect`'s state diff), and at `finish`. A modification that leaves the state equal to what it was is exempt.

`.off(showSkippedAssertions:)` skips what no assertion describes, to the latest state, before the next assertion. `showSkippedAssertions` defaults to `true`, so `.off()` reports each skip as a warning; pass `false` to skip silently. Under XCTest, IssueReporting turns warnings into failures. An assertion without `update` still asserts that nothing changed, in every mode, so even under `.off` the `send` below describes the action's own change:

```swift
let model = await TestModel(
    initialState: CounterState(),
    feature: Feature(interactor: CounterInteractor(counterClient: StubCounterClient(count: 4))),
    exhaustivity: .off(showSkippedAssertions: false)
)
await model.send(.task) { $0.isRefreshing = true }?.value  // the action's own change, still asserted
await model.finish()  // skips the refresh's modifications
```

`await model.setExhaustivity(.on)` turns exhaustivity back on mid-test.

The model also reports what is pending when it is deallocated, but its `isolated deinit` runs without the test's context. Under Swift Testing that report is an unattributed warning that cannot fail the test; under XCTest it fails whichever test is running. So end exhaustive tests with `finish()`.

### `TestViewModel`

Use `TestViewModel` for an interactor that is main-actor-isolated, such as one declared in a module with main-actor default isolation, and for tests that must run on the main actor. Its `init` and `send` are synchronous:

```swift
@MainActor
@Test
func hydratesOnTheMainActor() async {
    let model = TestViewModel(
        initialState: CounterState(),
        feature: Feature(interactor: CounterInteractor(counterClient: StubCounterClient(count: 4)))
    )
    model.timeout = .seconds(2)
    await model.send(.task) { $0.isRefreshing = true }?.value
    model.expect {
        $0.count = 4
        $0.lastUpdatedAt = StubCounterClient.date
        $0.isRefreshing = false
    }
    await model.finish()
}
```

### State equality

Assertions compare states with the feature's `areStatesEqual`:

- `Feature(interactor:)` supplies `==` for an `Equatable` state.
- For a state that is not `Equatable`, or a comparison that ignores generated values such as IDs, build the feature with `Feature(interactor:areStatesEqual:)`.
- `TestModel(initialState:feature:areStatesEqual:)` and `TestViewModel(initialState:feature:areStatesEqual:)` cover a feature without an equality; the feature's own equality takes precedence.
- With no equality at all, the test model reports an issue at `init` and every state assertion fails.

### Time

Inject an `EffectClock` and move time with the test shell's `advance(_:by:)`. The effect's `clock.sleep(for:)` registers on the clock before `send` returns. `advance` wakes every sleep that comes due, in deadline order, and lets each woken effect run to its next suspension before it goes on, so `expect` right after it sees what the woken effects committed. This test drives the [debounced search](#debouncing), with a `StubSearchClient` that answers `[query]`:

```swift
@available(iOS 26, macOS 26, watchOS 26, *)
@Test(.timeLimit(.minutes(1)))
func debouncedSearchUsesTheLatestQuery() async {
    let clock = EffectClock()
    let model = await TestModel(
        initialState: SearchState(),
        feature: Feature(interactor: SearchInteractor(searchClient: StubSearchClient(), clock: clock))
    )
    await model.send(.queryChanged("a")) { $0.query = "a" }
    await model.send(.queryChanged("b")) { $0.query = "b" }  // cancels "a" while it sleeps
    await model.advance(clock, by: .milliseconds(300))  // "b" wakes, searches and writes its results
    await model.expect { $0.results = ["b"] }
    await model.finish()
}
```

One `advance` moves a loop through every tick in its duration: each woken tick commits and sleeps again before the next one wakes. For the [ticker](#timers-and-clocks), built with `TickerInteractor(clock: clock, interval: .seconds(1))`:

```swift
let ticker = await model.send(.startTicking)
await model.advance(clock, by: .seconds(3))
await model.expect { $0.ticks = 3 }  // three modifications, one assertion
ticker?.cancel()  // cancel the loop; never await its task
await model.finish()
```

- Sleep with `try await clock.sleep(for:)`. `sleep(for:tolerance:)`, `Task.sleep(for:clock:)`, `sleep(until:tolerance:)` on a generic clock and any sleep inside a `@concurrent` function reach the clock only after hopping off the shell, so they register after `send` returned and `advance` can miss them: `EffectClock` reports each such sleep (`EffectClock registered this sleep late: …`).
- A woken effect runs only to its next suspension. When it then waits on a dependency that suspends, wait for that too, for example with `await task?.value`, before `expect`.
- Never await the task of a looping effect, even a cancelled one: `await task?.value` is not cancellation-aware, and a `.timeLimit` cannot end it. Cancel the task, then end with `finish()`, which is bounded by its timeout.
- To assert that a cancelled effect wrote nothing, first prove that it ended, then `expect`. A cancel ends its effect's sleep inside the `cancel()` call, so `advance` to when that sleep was due, which wakes a sleep that outlived the cancel, then await the effect's task. For a loop, whose task is never awaited, `expect { _ in }` after that `advance`, then end with `finish()`, which waits for the loop to end and reports anything it wrote.

### Production `ViewModel` tests

Test the production `ViewModel` only when you need to cover computed presentation members, observation, or event wiring. Reads go through the `ViewState` projection, exactly as in a view:

```swift
@MainActor
@Test
func countTextShowsTheFetchedCount() async {
    let viewModel = ViewModel(
        initialState: CounterState(),
        feature: Feature(interactor: CounterInteractor(counterClient: StubCounterClient(count: 4)))
    )
    await viewModel.sendViewEvent(.task)?.value
    #expect(viewModel.countText == "4")
}
```

## Development

Lattice requires Swift 6.2 tools or later: `Package.swift` declares `swift-tools-version: 6.2` and is the package's only manifest. CI builds on GitHub's `xcode-27` runner image (Xcode 27, Swift 6.4) and runs:

```bash
swift build --build-tests
bash scripts/negative-compile-checks.sh
swift test --skip-build
```

Run the library tests (Swift Testing) or the macro tests (XCTest) only:

```bash
swift test --filter LatticeTests
swift test --filter LatticeMacrosTests
```

`--filter` takes a regular expression that is matched against `Module.Suite/test` identifiers, not folder names, so `SchedulingTests` also matches `ActorModelSchedulingTests`. Focused suites:

```bash
# @FeatureState expansion snapshots
swift test --filter FeatureStateMacroTests
swift test --filter FeatureStateSupportMacrosTests

# ViewState projection runtime
swift test --filter '\.ProjectionTests'
swift test --filter ViewStateProjectionTests
swift test --filter ViewStateCollectionTests

# view model, bindings, scopes and observation
swift test --filter FeatureViewModelTests
swift test --filter ViewModelBindingTests
swift test --filter ScopedViewModelTests
swift test --filter EnumCaseScopingTests
swift test --filter FineGrainedObservationTests
swift test --filter ViewModelObservationTests

# the core: scheduling, modifications, isolation exits, parallelism
swift test --filter '\.SchedulingTests'
swift test --filter ModificationTests
swift test --filter CoreExitTests
swift test --filter ParallelismTests
swift test --filter IsolationTests

# effects, ActorModel, the effect clock
swift test --filter '\.AutoCancelTests'
swift test --filter EffectIDTests
swift test --filter ActorModel
swift test --filter EffectClock

# test shells
swift test --filter TestModel
swift test --filter TestViewModelTests
```

- `IsolationTests` selects the three isolation regression suites, `ViewModelIsolationTests`, `TestModelIsolationTests` and `ActorModelIsolationTests`, not the whole `IsolationTests` folder.
- `ActorModel` selects the three `ActorModel*` suites, `TestModel` every `TestModel*` suite, and `EffectClock` `EffectClockTests` and `EffectClockTestViewModelTests`.
- `ParallelismTests` compares the `TestModel` and `ActorModel` cases with the serial `ViewModel` ones; filtering it down to one variant skips the comparison.

Run the negative compile checks after a build (CI runs them):

```bash
swift build
bash scripts/negative-compile-checks.sh
```

The script compiles `Tests/NegativeCompileChecks` against the built module in two lanes:

- `-typecheck`: the fixtures must compile without flags, and each `LEAK_*` flag (a `@Domain` member reached through the view model, a child, an optional child, a collection element, a key path, a binding, a scope or an enum payload, and the raw state) and `GENERIC_STATE` must fail with its expected diagnostic.
- `-emit-sil -wmo -o /dev/null`, because region-isolation diagnostics come only from SIL passes: `NO_SENDABLE_BASELINE` (a non-`Sendable` state, action and dependency under `ViewModel`) must compile with `-warnings-as-errors`; `PERFORM_IN_EFFECT` must fail with `'perform' is unavailable from asynchronous contexts`, and `MAINACTOR_INTERACTOR_TO_TESTMODEL` (a main-actor interactor handed to `TestModel`) must fail with a `sending … risks causing data races` error whose note is `sending main actor-isolated value … to actor-isolated initializer`.

Pass the build's options in `SWIFT_BUILD_FLAGS` when they are not the defaults, for example `SWIFT_BUILD_FLAGS="--scratch-path <dir>"`.

Run the projection read benchmark (release only; it is compiled out of debug builds):

```bash
swift test -c release --filter ProjectionReadBenchmark
```

Formatting is handled by the pre-push hook with `swift-format`. Do not run `swift-format` manually.

Rebuild the macro tool after macro source changes (it builds the package in release and copies the `LatticeMacros` tool to `Macros/LatticeMacros`):

```bash
scripts/rebuild-macro.sh
```

Set `SKIP_LATTICE_MACRO_BUILD=1` or `SKIP_LATTICE_MACRO_BUILD=true` to skip macro build steps when needed.

Sync local Codex and Claude skill folders:

```bash
scripts/sync-skills.sh
```

## Project Layout

- `Sources/Lattice`: the runtime library.
  - `Domain/`: `Interactor`, `InteractorBuilder` and the `Interactors` (`Interact`, `Merge`, `MergeMany`, `When`, …); `Effects.swift`, the `Effects` handle; `EffectID.swift`; `Clock+Sleep.swift`, the `clock.sleep(for:)` overload effects call.
  - `Internal/Core.swift`: the nonisolated runtime every shell hosts. `Internal/Concurrency/` holds `Task+Immediate`, `StartOnMainActor` and `DefaultIsolation`; `Internal/Runtime/` holds `EnumMetadata` and `RuntimeMetadata`, which give the enum tags that automatic cancellation keys on.
  - `Observation/`: `FeatureState`, the `ViewState` projection and its collection, and the observation registrar.
  - `Presentation/`: `Feature/`, `ViewModel/` (`ViewModel`, `ScopedViewModel` and the bindings) and `ActorModel/`.
  - `Testing/`: `TestHost.swift`, the engine both test shells share, `TestModel.swift`, `TestViewModel.swift`, `EffectClock.swift` (the test clock and the shells' `advance(_:by:)`), `Received.swift`, `Exhaustivity.swift` and failure reporting. The CocoaPods pod excludes it.
  - `Macros.swift`: the macro declarations.
- `Sources/LatticeMacros`: macro implementations.
- `Macros/`: where `scripts/rebuild-macro.sh` puts the release `LatticeMacros` tool for tooling and CocoaPods; the binary is not checked in.
- `ExampleProject/`: sample app and package-based examples (`Search`, `Todos`, `TimerLeak`, `ScopedComposition`, `FineGrained`).
- `Tests/`: library and macro tests, plus `Tests/NegativeCompileChecks`, the fixtures of `scripts/negative-compile-checks.sh` (not a SwiftPM target).
- `specs/`: source-driven design and behavior docs.
