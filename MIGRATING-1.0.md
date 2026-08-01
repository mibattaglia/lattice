# Migrating to Lattice 1.0

Lattice 1.0 replaces the `Emission`-based effect system with an imperative effects runtime,
removes every `Sendable` requirement from the library, and collapses the domain-state →
view-state split into a single `@FeatureState` type. Migration is mechanical: two passes over
your interactors, one pass over your state types, one pass over your tests.

## Requirements

- Swift 6.2 toolchain (Xcode 26) or later. Older toolchains cannot build 1.0.
- iOS 17 / macOS 14 / watchOS 10 deployment floors are unchanged.

## What changed

| Before (0.x) | After (1.0) |
|---|---|
| `func interact(state:action:) -> Emission<Action>` | `func interact(state:action:effects:)` — synchronous, returns `Void` |
| `Emission` (`.none`/`.action`/`.perform`/`.observe`/`.merge`/`.append`) | Deleted. Effects are launched with `effects.perform` and re-enter via `effectState.modify` |
| `Debouncer`, `Emission.debounce(using:)`, `Interactors.Debounce` | Deleted. Per-call-site task auto-replacement + `clock.sleep` |
| `Sendable` constraints on `DomainState`/`Action`/interactors | Removed everywhere |
| `UncheckedSendableInteractor`, `.uncheckedSendable()`, `.eraseToAnyInteractorUnchecked()` | Deleted; plain `.eraseToAnyInteractor()` now accepts everything |
| `@ObservableState` + handwritten `ViewState` structs | One `@FeatureState` state type: `@Domain` marks interactor-only members; everything else is view-visible |
| `ViewStateReducer` + `BuildViewState` + `DefaultValueProvider`/`initialViewState(for:)` | Deleted. Visible computed properties on the state type *are* the derived view output |
| `areStatesEqual` strategies | Deleted. Per-member `==` gating inside the generated commit diff — granularity is built in |
| `Feature(interactor:reducer:)` | `Feature(interactor:)`, or skip the bundle: `ViewModel(initialState:interactor:)` |
| `viewModel.viewState.someLabel` reads | `viewModel.someLabel` — a generated `@dynamicMemberLookup` projection; `@Domain` members don't compile from views |
| Buffered-receive `TestViewModel` (`send`/`receive` action buffering) | Snapshot-diff `TestViewModel` (`send(_:changes:)` / `expect(timeout:changes:)`) |

**Unchanged:** `sendViewEvent(_:) -> EventTask`, `scope`/`ScopedViewModel`, `sending`
bindings, `when(state:action:child:)` composition, `TestClock`.

## Pass 1: interactor signatures

1. Delete `: Sendable` (and `@unchecked Sendable`) from state, actions, interactors,
   and dependency protocols. They are no longer required — don't keep them "just in
   case"; keeping them forces your dependencies to stay Sendable too.
2. `Interact { state, action in … }` closures that only mutate state: delete every
   `return .none` (and `return`-before-switch-end). The two-argument overload still exists.
3. Closures that launch effects take the third parameter: `Interact { state, action, effects in … }`.

## Pass 2: emission idioms

### `.action` (synchronous self-send)

Before:

```swift
case .saveButtonTapped:
    state.isSaving = true
    return .action(.validate)
```

After — call shared logic directly; update-phase re-entry no longer exists:

```swift
case .saveButtonTapped:
    state.isSaving = true
    validate(&state)          // shared validation logic
```

(If you genuinely need action re-entry, it exists only from the effect phase:
`effects.perform { effectState in try effectState.send(.validate) }` — but prefer the shared function.)

### `.perform` returning an action

Before — two action cases, one existing only to receive the result:

```swift
case .fetchData:
    state.isLoading = true
    return .perform { [api] in
        let data = try? await api.fetch()
        return .dataLoaded(data)
    }
case .dataLoaded(let data):
    state.isLoading = false
    state.data = data
    return .none
```

After — one case; the effect mutates state directly. **Delete `.dataLoaded` from the Action
enum** (finding response-only cases to delete is most of this pass):

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

Error handling moves inside the closure: `do/catch` around the `await`, with a
`try effectState.modify` in each branch. The old `return nil` ("emit nothing") maps to simply
returning from the closure.

### `.observe` (stream → action per element)

Before:

```swift
case .task:
    return .observe { [locationClient] in
        AsyncStream { continuation in
            Task {
                for await location in locationClient.locations {
                    continuation.yield(.locationChanged(location))
                }
            }
        }
    }
case .locationChanged(let location):
    state.location = location
    return .none
```

After — a `for await` loop; delete `.locationChanged`:

```swift
case .task:
    effects.perform { [locationClient] effectState in
        for await location in locationClient.locations {
            effectState.location = location
        }
    }
```

Re-dispatching `.task` replaces the previous subscription (same `perform` call site). Leaving the
enclosing `when` scope, or tearing down the `ViewModel`, cancels it.

### `.merge` (concurrent effects)

Before:

```swift
case .refresh:
    return .merge(
        .perform { .profileLoaded(try? await api.profile()) },
        .perform { .feedLoaded(try? await api.feed()) }
    )
```

After — just call `perform` twice; the tasks run concurrently:

```swift
case .refresh:
    effects.perform { [api] effectState in
        let profile = try await api.profile()
        effectState.profile = profile
    }
    effects.perform { [api] effectState in
        let feed = try await api.feed()
        effectState.feed = feed
    }
```

(`.append` / `.then` — sequential effects — become sequential `await`s inside **one** `perform`
closure.)

### Debounce

Before:

```swift
let debouncer = Debouncer<ContinuousClock, SearchAction?>(for: .milliseconds(300), clock: .init())
…
case .queryChanged(let query):
    state.query = query
    return .perform { [searchClient] in
        .searchResponse(await searchClient.search(query))
    }
    .debounce(using: debouncer)
```

After — the first `perform` at a call site replaces that call site's in-flight task, so
a leading `clock.sleep` *is* the debounce window. Inject the clock (use `TestClock` in tests):

```swift
let clock: any Clock<Duration>
…
case .queryChanged(let query):
    state.query = query                       // synchronous mutation, visible immediately
    effects.perform { [searchClient, clock] effectState in
        try await clock.sleep(for: .milliseconds(300))   // cancelled by the next keystroke
        let results = await searchClient.search(query)
        effectState.results = results
    }
```

`Interactors.Debounce(for:_:)` wrappers are deleted the same way: move the `clock.sleep` into
the leaf effect. To coalesce *across* call sites, share one `@EffectID` between the
`perform(id:)` calls.

### `When` / child features

`when(state:action:child:)` and `Interactors.When` keep their exact shapes — composition code
does not change, except that `Sendable` constraints on children are gone and child effects now
write through the state lens automatically (no more `Emission.map` re-embedding, which was
internal anyway).

New behavior to know about: **if the parent's enum leaves the child's case (or the scoped
optional becomes `nil`) while a child effect is in flight, the child's tasks are cancelled and
any straggling `effectState.modify`/`effectState.send` is dropped silently.** This is the
navigation-dismissed-mid-request contract — delete any hand-rolled nonce/generation guards
that existed to protect against stale responses after dismissal.

## Pass 3: collapse view state

Handwritten `ViewState` structs, `@ObservableState`, `ViewStateReducer`, and `areStatesEqual`
are gone. A feature carries **one** state type: annotate it `@FeatureState`, mark
interactor-only members `@Domain`, and express every reducer-computed property as a visible
computed property — its output is diffed at commit, so views re-render only when it actually
changes. Cost is not a reason to avoid this: derived output is computed at most once per
commit, only while something on screen reads it, and reads are served from a host-side cache
— an expensive aggregation in a computed property is fine; moving it into `@Domain` storage
updated by the interactor is a recommendation for extreme cases, not a requirement.

Before — four artifacts:

```swift
struct SearchDomainState {
    var rawResults: [SearchResult] = []
    var query: String = ""
    var isLoading: Bool = false
}

@ObservableState
struct SearchViewState: DefaultValueProvider, Equatable {
    var query: String = ""
    var isLoading: Bool = false
    var subtitle: String = ""
    static let defaultValue = Self()
}

@ViewStateReducer<SearchDomainState, SearchViewState>
struct SearchViewStateReducer: Sendable {
    var body: some ViewStateReducerOf<Self> {
        BuildViewState { domain, view in
            view.query = domain.query
            view.isLoading = domain.isLoading
            view.subtitle = "\(domain.rawResults.count) results"
        }
    }
}

let viewModel = ViewModel(
    initialDomainState: SearchDomainState(),
    feature: Feature(interactor: SearchInteractor(), reducer: SearchViewStateReducer()),
    areStatesEqual: .equatable
)
```

After — one:

```swift
@FeatureState
struct SearchState {
    @Domain var rawResults: [SearchResult] = []      // interactor-only: invisible to views
    var query: String = ""
    var isLoading: Bool = false
    var subtitle: String { "\(rawResults.count) results" }   // derived view output
}

let viewModel = ViewModel(
    initialState: SearchState(),
    interactor: SearchInteractor()
)
```

The recipe, per feature:

1. For each ViewState property copied verbatim from domain state, delete it — the domain
   property is already view-visible.
2. For each property *computed* in the reducer, move the expression into a visible computed
   property on the state type.
3. Mark every remaining interactor-only member `@Domain` (or `private`).
4. Delete the ViewState struct, the reducer, the `reducer:` argument, and any
   `areStatesEqual:`/`DefaultValueProvider`/`initialViewState(for:)` code.
5. View code: reads drop the `viewState` hop (`viewModel.viewState.subtitle` →
   `viewModel.subtitle`); member names usually survive because they were the ViewState's
   names. A read of a `@Domain` member no longer compiles — that's the fence working; derive
   what the view needs as a visible computed property instead.

Rows in a list: store elements as `@FeatureState` values in an `IdentifiedArrayOf` member and
put each row's rendering data in the element's visible computed properties — don't rebuild a
`[RowViewData]` array in a computed property (the macro warns; the migrated Search example in
`ExampleProject/` is the reference).

## Pass 4: tests

Old-style tests (buffered receives) do not compile and have no shims. The rewrite is
one-to-one per test:

Before:

```swift
let model = TestViewModel(initialDomainState: SearchState(), feature: feature)

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

After — `send` asserts the synchronous mutation exactly as before; the effect's `modify`
re-entry is asserted with `expect(changes:)` instead of receiving a response action (which no
longer exists):

```swift
let clock = TestClock()
let model = TestViewModel(
    initialDomainState: SearchState(),
    interactor: SearchInteractor(searchClient: SearchClientStub(), clock: clock)
)

await model.send(.queryChanged("lattice")) {
    $0.query = "lattice"
    $0.isLoading = true
}

await clock.advance(by: .milliseconds(300))

await model.expect {
    $0.isLoading = false
    $0.results = ["Lattice"]
}
```

Mapping table:

| Old test API | New idiom |
|---|---|
| `send(_:) { … }` | `send(_:changes:)` — unchanged role |
| `receive(action) { … }` for `.perform`/`.observe` output | `expect(timeout:changes:)` per `effectState.modify` commit |
| `receive(\.case)` for `effectState.send` re-entry | `receive(\.case, timeout:changes:)` — kept, now rare |
| `receive(matching:)` predicate matching | Dropped. Use the equatable or case-path overloads |
| `task.finish()` quiescence | await the task returned from `send`, `finish()`, or `dismount()` at test end |
| `skipReceivedActions()` | `skipPendingCommits()` — consumes all pending commits without asserting them |
| `skipInFlightEffects()` | Deleted — cancel via `dismount()` (or `TestEventTask.cancel()`) |
| `TestClock` + advance | unchanged |
| reducer unit tests / `initialViewState` fixtures | deleted as a category — assert view output by reading the projection (`#expect(model.projection.subtitle == "3 results")`) |

API details worth knowing while porting:

- On `expect`/`receive`, the optional `timeout:` parameter comes **before** the trailing
  `changes:` closure: `await model.expect(timeout: .seconds(2)) { … }`.
- Effects launch synchronously in-domain and run up to their first suspension point, so any
  commit an effect makes *before* first suspending is already pending by the time `send`
  returns — `expect`/`receive` for those commits succeed without any actual waiting.
- Exhaustivity is on by default: pending commits must be asserted (or skipped with
  `skipPendingCommits()`) before later sends and before the model deinits; prefer an explicit
  `dismount()` at test end so failures land at a useful source location.

Delete `Sendable` from test fixtures; stubs can be plain classes now.
