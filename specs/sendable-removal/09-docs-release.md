# 09 — Docs, Examples, Release

Workstream 9 of the Sendable-removal rework. Lands last, after plans 1–8 are merged and
`swift test` is green on the new runtime. Everything here is documentation, example code, and
release mechanics — no library source changes. Conforms to the pinned contract in `README.md`
(this directory); every code sample below uses the pinned shapes: `interact(state:action:effects:)`,
`effects.perform` / `effectState.modify` / `effectState.send` / `effectState.state`, `@EffectID`,
debounce-by-replacement, `When` drop semantics, single `@FeatureState`/`@Domain` state types
with generated view projections (plan 05), snapshot-diff testing.

One dependency note: plan `07-testing.md` owns the exact spelling of the test API. This plan
writes testing docs against the TCA26 `TestStore` shapes the README pins
(`send(_:changes:)`, `receive(_:changes:)`, `expect(changes:)`, `dismount()`); if plan 07 lands
with different spellings, the testing sections here are updated mechanically before release.
Likewise, plan 05 defers the exact `Feature`/`ViewModel` construction spelling to plan 06; this
plan writes `Feature(interactor:)` + `ViewModel(initialState:feature:)` — if plan 06 dissolves
the bundle into `ViewModel(initialState:interactor:)`, the construction lines here are updated
the same way.

## Overview

| Artifact | Change | Size |
|---|---|---|
| `README.md` (root) | Rewrite: features list, installation version, quick start, new hero example, architecture, testing sections | L |
| `skills/lattice/SKILL.md` + `resources/` | Rewrite core + async + view-state sections (`@FeatureState`/`@Domain` replace `@ObservableState`/`ViewStateReducer`); rewrite `advanced-composition.md` effect sections | M |
| `skills/lattice-testing/SKILL.md` + `resources/async-and-time.md` | Full rewrite to snapshot-diff model | M |
| `skills/lattice-case-paths/SKILL.md` | Targeted edits (Sendable removal, `receive` section, enum view state → `@FeatureState`) | S |
| `skills/lattice-modern-swiftui/SKILL.md` | Rewrite view-state sections to `@FeatureState` + projection reads; event/binding layer survives | M |
| `skills/lattice-observable-models/SKILL.md` | Targeted edits (interactor snippet, async wording, `Feature(interactor:)` construction) | S |
| `.claude/skills/` | Regenerated via `scripts/sync-skills.sh` (never hand-edited) | — |
| `ExampleProject/` (5 packages + app) | Migrate all interactors/tests; Search package shown in full below | M |
| `specs/*.md` (pre-rework design docs) | Archival notes on the 7 obsoleted docs + `specs/README.md`; no rewrites | S |
| `AGENTS.md` | Concept list, test-filter commands, deleted-type references | S |
| `MIGRATING-1.0.md` (new) | Consumer migration guide, full content below | M |
| `Lattice.podspec` + tag + GitHub release | `s.version = '1.0.0'`, dependency prune, release order per AGENTS.md | S |

Version decision: **1.0.0**. The rework deletes public API (`Emission`, debounce stack,
`InteractorTestHarness`-era testing) and changes the core protocol signature — a major bump is
mandatory, and the runtime finally matching the library's long-term shape is the natural 1.0.
Current released version is 0.3.1; tags are plain (`0.3.1`, no `v` prefix), so the new tag is
`1.0.0`.

---

## 1. `README.md` rewrite

### Outline (section by section)

| Section | Disposition |
|---|---|
| Intro paragraph | Reworded: add "single-isolation-domain runtime — no `Sendable` requirements on your types", "one annotated state type per feature", "Swift 6.2+" |
| Core Features | Rewrite bullet list (below) |
| Installation | `from: "1.0.0"`; add toolchain floor note (Xcode 26 / Swift 6.2, per plan 01) |
| Quick Start (counter) | Keep structure; drop `Sendable`/`return .none`; 2-arg `Interact` overload; state gains `@FeatureState` |
| **Hero example** (new, replaces "Counter + API Modeling Example") | Full feature showing `interact` + `effects.perform` + `effectState.modify` + one `@FeatureState` state type (below) |
| Architecture | Rewrite steps 3–6 around the update phase / effect phase / commit funnel |
| State Modeling | Rewrite around the single `@FeatureState` type: `@Domain` members are the domain model, visible computed properties are the view contract |
| Bindings | Keep shape (`sending` bindings survive); reads retarget from `viewState` key paths to the projection; strip `Sendable` |
| Debouncing | Delete section; replace with short "Debounce by replacement" subsection under Effects |
| Composition / Scoped View Composition | Keep; strip `Sendable`; add one sentence on the dismissal-drop contract under `when` |
| Testing with `TestViewModel` | Rewrite to snapshot-diff model (sync with plan 07's final API) |
| Testing (commands) | Update filter list: drop `EmissionDebounceTests`/`DebounceInteractorTests`/`Append`/`Observe`; add `EffectsHandleTests`, `EffectCancellationTests`, `EffectIDTests`, `ScopedEffectsTests`, `InteractorGraphPathTests` |
| Development / Project Layout | Keep; "emissions" wording → "effects" |

New Core Features bullets:

```markdown
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
```

### Hero example (full production Swift, replaces "Counter + API Modeling Example")

Demonstrates the pinned surfaces — `interact`, `effects.perform`, `effectState.modify`, and one
`@FeatureState` state type with `@Domain` members and derived view output — plus a
non-Sendable dependency, error handling, and debounce-by-replacement. This is the example the
migration guide and both major skills reuse, so it is written once here, in full:

````markdown
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

    var query = ""
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
    @State private var viewModel: ViewModel<Feature<WeatherSearchAction, WeatherSearchState>>

    init(weatherClient: WeatherClient) {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: WeatherSearchState(),
                feature: Feature(
                    interactor: WeatherSearchInteractor(
                        weatherClient: weatherClient,
                        clock: ContinuousClock()
                    )
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

- **One state type.** There is no handwritten ViewState struct and no `ViewStateReducer` —
  `@Domain` fences `isSearching`/`errorMessage` and the per-result internals off from views,
  and the visible computed properties (`statusText`, each row's `title`/`detail`) *are* the
  derived view output. `viewModel.isSearching` does not compile; `viewModel.statusText`
  invalidates its readers only when the derived string actually changes (per-member diff at
  commit — there is no `areStatesEqual` strategy to configure).
- **One action case.** There is no `.searchResponse` — the effect mutates state directly via
  `effectState.modify`, and the same commit diff runs for that re-entry exactly as it does for
  synchronous mutations.
- **Nothing is `Sendable`.** `WeatherClient`, the state, and the action enum are plain
  types. The effect closure runs in the feature's isolation domain (the main actor under
  `ViewModel`), so captures never cross an isolation boundary.
- **Debounce is task replacement.** No debounce API: re-dispatching the same action replaces
  the in-flight task at that location; `clock.sleep` provides the quiet period. Inject
  `TestClock` in tests.
````

Architecture section replacement:

```markdown
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
```

---

## 2. Skills update matrix

All edits happen in `skills/`; `.claude/skills/` is regenerated with `scripts/sync-skills.sh`
(mtime-based — edit only the `skills/` side, then sync; deletions, if any, are removed manually
on both sides per AGENTS.md).

| Skill | Files | Sections changed | Depth |
|---|---|---|---|
| `lattice` | `SKILL.md`, `resources/advanced-composition.md`, `resources/bootstrapping.md` | "Build a basic feature" (drop Sendable/`.none`; state gains `@FeatureState`); "Async work" (full rewrite → effects); view-state sections (the `@ObservableState` + `@ViewStateReducer` + `DefaultValueProvider` + `areStatesEqual` teaching collapses into `@FeatureState`/`@Domain` + visible computed properties); "Child features" (+drop contract sentence); advanced-composition: "Sequential effects", "Async streams", "Debounced effects" (all rewritten to effect idioms), fine-grained-observation notes retargeted from `@ObservableState` getter chains to projection reads; bootstrapping: strip `Sendable`; the ViewState/reducer checklist steps collapse to "annotate the state `@FeatureState`, mark interactor-only members `@Domain`" | Full rewrite of core examples (below) |
| `lattice-testing` | `SKILL.md`, `resources/async-and-time.md` | Everything: core tools, step-wise example, async output, buffered-work semantics all replaced by the snapshot-diff model; fixtures drop the reducer (`Feature(interactor:)`); view assertions read the projection | Full rewrite (below) |
| `lattice-case-paths` | `SKILL.md` | Strip `Sendable` from enum examples; "Testing buffered receives" → "Asserting received actions" rewritten for the new `receive` (only `effectState.send` re-entries produce receivable actions now); the `@ObservableState` enum view-state snippet becomes a `@FeatureState` enum read through case-accessor projections, and the reducer `modify`-in-place guidance is deleted (no reducer exists; case granularity comes from `@FeatureState` payloads); case-path ergonomics and `sending` bindings survive | Targeted |
| `lattice-modern-swiftui` | `SKILL.md` | "Feature with ViewStateReducer" and every `viewModel.viewState.x` read rewritten to the single `@FeatureState` type + projection reads (`viewModel.x`); `DefaultValueProvider`/`initialViewState(for:)` guidance deleted; `sendViewEvent`/`EventTask`/bindings/scoped composition survive | Rewrite of view-state sections |
| `lattice-observable-models` | `SKILL.md` | Interactor snippet loses `Sendable` + `return .none`; "Async work" paragraph rewords "emissions" → "effects"; ViewModel construction drops the reducer (`Feature(interactor:)`); rest survives | Targeted |

Also update each skill's `description` front-matter only where it names deleted concepts
(the `lattice` description says "view state reducers" — reword to "feature state projections";
the rest mention interactors/view models/testing, all of which survive). Same for
`skills/skill-rules.json` trigger patterns (`ViewStateReducer`, `ObservableState` content
patterns → `FeatureState`).

### `lattice` SKILL.md — rewritten core sections (full)

"Build a basic feature" becomes:

````markdown
## Build a basic feature

```swift
import Lattice

@FeatureState
struct CounterState {
    var count = 0
    var countText: String { "\(count)" }
}

enum CounterAction {
    case decrementButtonTapped
    case incrementButtonTapped
}

@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .decrementButtonTapped:
                state.count -= 1
            case .incrementButtonTapped:
                state.count += 1
            }
        }
    }
}
```

- Do name actions after user intent (`incrementButtonTapped`), not the state change.
- One state type: annotate it `@FeatureState`. Mark interactor-only members `@Domain`;
  everything else — stored or computed — is what views read (`viewModel.count`,
  `viewModel.countText`). There is no separate ViewState type and no reducer: visible
  computed properties *are* the derived view output, diffed by output at commit.
- No `Sendable` conformances anywhere: state, actions, interactors, and dependencies are plain
  types living in the feature's isolation domain.
- Pure state mutation uses the two-argument `Interact { state, action in }` overload; take the
  third `effects` parameter only when you launch async work.
````

"Async work" becomes (this is the skill's core effects example — kept in lockstep with the
README hero example):

````markdown
## Async work

Launch effects imperatively with `effects.perform` during the synchronous update phase; effects
re-enter by mutating state directly with `effectState.modify`. There are no follow-up "response"
actions.

```swift
enum SearchAction {
    case queryChanged(String)
}

@Interactor<SearchState, SearchAction>
struct SearchInteractor {
    let searchClient: SearchClient   // plain protocol, no Sendable
    let clock: any Clock<Duration>

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .queryChanged(let query):
                state.query = query          // synchronous mutation, visible immediately
                state.isLoading = true
                effects.perform { [searchClient, clock] effectState in
                    try await clock.sleep(for: .milliseconds(300))   // debounce window
                    do {
                        let results = try await searchClient.search(query)
                        try effectState.modify { state in
                            state.isLoading = false
                            state.results = results
                        }
                    } catch {
                        try effectState.modify { state in
                            state.isLoading = false
                            state.results = []
                        }
                    }
                }
            }
        }
    }
}
```

- `effects.perform` is legal only during the update phase (inside `interact`); it launches the
  operation in the feature's isolation domain.
- `effectState.modify` is legal only from inside a launched effect; it throws `CancellationError`
  if the feature was torn down, so spell it `try effectState.modify { … }`.
- Re-dispatching the same action **replaces** the previous in-flight task at that action
  location — that auto-replacement plus `clock.sleep` *is* debouncing; there is no debounce API.
- Streams are `for await` loops inside `perform`:

```swift
case .task:
    effects.perform { effectState in
        for await status in networkMonitor.statusUpdates {
            effectState.isOnline = status.isConnected
        }
    }
```

- Sequential work is sequential `await`s inside one `perform` closure; concurrent work is
  multiple `perform` calls.
- Name a long-lived effect with `@EffectID var recording` and `effects.perform(id: recording)`
  to cancel (`effects.perform { _ in recording.cancel() }`) or await (`try await recording()`) it
  explicitly.
- CPU-bound work should hop off-domain via a consumer-side `@concurrent` function taking
  `sending` values, then re-enter with `effectState.modify`.

Advanced effect orchestration (streams, `EffectID`, composition, dismissal semantics) is
covered in `resources/advanced-composition.md`.
````

`resources/advanced-composition.md` section rewrites (idioms only; each replaces the existing
section body):

- **Sequential effects**: delete `.append`/`.then` content; show one `perform` with sequential
  `await`s, and `try await someEffectID()` for cross-effect ordering.
- **Async streams**: delete `.observe`; show the `for await … try effectState.modify` loop, note
  re-dispatch replacement and scope-departure cancellation for teardown.
- **Debounced effects**: delete `Debouncer`/`Interactors.Debounce`; show `clock.sleep` +
  auto-replacement (same snippet as SKILL.md), plus the shared-`@EffectID` variant for
  cross-location coalescing.
- **Navigation-driven state**: add the drop contract — a child effect's `modify`/`send` after
  its `When` case departs is dropped silently and the child's tasks are cancelled; design
  child effects so this is safe (it is, by default, because re-entry is just a state write).

### `lattice-testing` SKILL.md — full rewrite (core content)

````markdown
---
name: lattice-testing
description: Test Lattice features with snapshot-diff TestViewModel assertions and TestClock.
license: MIT
metadata:
  short-description: Testing patterns for Lattice.
---

# Lattice Testing

## Goal

Write deterministic, exhaustive tests for Lattice features with the snapshot-diff testing
model: every state change — synchronous mutations from `send` and asynchronous re-entries from
`effectState.modify` — is asserted as a diff against the previous state.

## Core tools

- `TestViewModel<F>` — hosts the feature with a test core; fails the test for any unasserted
  state change or unasserted received action.
- `send(_:changes:)` — dispatch an action, assert the synchronous update-phase mutation.
- `expect(changes:)` — assert the next state change committed by an effect's `effectState.modify`.
- `receive(_:changes:)` — assert an action re-entered via `effectState.send` (rare; most effects
  use `modify` and are asserted with `expect`).
- `TestClock` from `Clocks` — drive `clock.sleep`-based debounce windows deterministically.
- `dismount()` — tear the feature down and assert all effects wound down.

## Snapshot-diff feature test

```swift
import Clocks
import Lattice
import Testing

@Suite
@MainActor
struct SearchInteractorTests {

    @Test
    func debouncedSearch() async throws {
        let clock = TestClock()
        let model = TestViewModel(
            initialState: SearchState(),
            feature: Feature(
                interactor: SearchInteractor(searchClient: SearchClientStub(), clock: clock)
            )
        )

        // Update phase: synchronous mutations asserted immediately.
        model.send(.queryChanged("latt")) {
            $0.query = "latt"
            $0.isLoading = true
        }

        // Typing again replaces the in-flight task (debounce restart) — same sync assert.
        model.send(.queryChanged("lattice")) {
            $0.query = "lattice"
        }

        // Cross the debounce window; only the second search runs.
        await clock.advance(by: .milliseconds(300))

        // Effect re-entry: assert the `effectState.modify` diff.
        try model.expect {
            $0.isLoading = false
            $0.results = ["Lattice"]
        }
    }
}
```

## Rules

- Assert **every** state change: an unasserted `modify` from an effect fails the test at the
  end of scope (exhaustive by default).
- Diffs assert the state value — `@Domain` members included; only *views* are fenced off from
  domain members. View output is asserted by reading the projection
  (`#expect(model.statusText == "1 result")`) — no ViewState fixtures, no reducer unit tests.
- `send` asserts only the update phase. Effect output is asserted with `expect(changes:)` in
  commit order.
- `receive(\.someAction) { … }` exists only for effects that re-enter with `effectState.send`;
  if your feature never calls `effectState.send`, you never call `receive`.
- Time-based effects: inject `any Clock<Duration>` and pass `TestClock`; advance it past the
  window, then `expect` the re-entry. Never sleep in tests.
- Dismissal contract: to test navigation-dismissed-mid-request, `send` the action that leaves
  the child's case, then verify no further diffs arrive — the child's straggler `modify` is
  dropped and its tasks are cancelled.
- Non-Sendable fixtures are the norm: stub clients can be simple classes; nothing in a test
  needs `Sendable` or `@unchecked`.

> Exact assertion API spellings are owned by the testing plan (`specs/sendable-removal/07-testing.md`);
> this skill is updated in the same PR that lands it.
````

`resources/async-and-time.md` is rewritten in the same style: "Root send scopes" → effect
tasks and `EventTask.finish()`; "Time control" → `TestClock` + replacement-debounce example;
"Buffered async output" → deleted (nothing buffers; effects commit `modify`s, asserted with
`expect`).

### `lattice-case-paths` SKILL.md — targeted edits

- Drop `: Sendable` from every enum declaration in examples.
- Replace the "Testing buffered receives" section:

````markdown
## Asserting sent-back actions in tests

Most effects re-enter via `effectState.modify` and are asserted with `expect(changes:)`. When an
effect re-enters with `effectState.send`, assert it by case key path:

```swift
try await model.receive(\.readyToClose) {
    $0.phase = .closed
}
```
````

- Everything else (`is`, `[case:]`, `modify` on `@CasePathable` values, enum-case scoping,
  `sending` bindings) is untouched — those APIs all survive.
- The `@ObservableState` enum view-state snippet becomes a `@FeatureState` enum: the
  `switch viewModel.viewState` read becomes case-accessor projection reads
  (`if let detail = viewModel.detail { … }`), and the "mutate the active payload in place in
  reducers" guidance is deleted — there is no reducer; same-case granularity comes from making
  the payload `@FeatureState` (plan 05 §4.2).

### `lattice-modern-swiftui` / `lattice-observable-models` — edits

- Strip `Sendable` from example type declarations.
- `lattice-observable-models`: the `CounterInteractor` snippet drops `return .none`; the
  "Async work" paragraph's "emissions" wording becomes "effects"; ViewModel construction
  drops the reducer (`Feature(interactor:)`); the guidance itself (async work lives in the
  interactor; views await `EventTask`) is unchanged.
- `lattice-modern-swiftui`: the "Feature with ViewStateReducer" section is rewritten to the
  single `@FeatureState` type (same collapse as the README hero, in miniature); every
  `viewModel.viewState.x` read becomes a projection read (`viewModel.x`); the
  `DefaultValueProvider`/`initialViewState(for:)` and "keep view state simple / use a reducer
  to transform domain state" guidance is replaced by the visibility rule (mark interactor-only
  members `@Domain`; visible computed properties are the view contract). `sendViewEvent`/
  `EventTask`/`sending` bindings and scoped view composition survive. Verify with a grep that
  the file mentions none of `ViewStateReducer`, `@ObservableState`, `viewState`, `Emission`
  after the rewrite.

---

## 3. ExampleProject migration

Feature inventory (all under `ExampleProject/`, each a local package consumed by the shared
Xcode workspace app):

| Package | Feature | Old-runtime surface to migrate |
|---|---|---|
| `SearchExamplePackage` | Weather search: debounced query + per-row forecast fetch + `when` composition | `Debouncer`, `.perform` + response actions, request-nonce guards, `when(state:action:)` over enum case, `Sendable` everywhere, `@ObservableState` enum view state + `SearchViewStateReducer` with the identity-preserving case-merge dance |
| `TodosExamplePackage` | Todo list with debounced auto-sort | `Debouncer` + `.perform { .applyAutoSort }` |
| `TimerLeakExamplePackage` | Long-lived timer stream, leak demonstration | `.observe` stream |
| `ScopedCompositionExamplePackage` | Scoped child views, phase enum | `.perform`, `.observe` |
| `FineGrainedExamplePackage` | Fine-grained observation demo | Sync-only interactor: `Sendable`/`.none` strip + the ViewState/reducer collapse (the demo becomes a direct showcase of `@FeatureState` per-member projection granularity) |
| `ExampleProject` app + tests | Hosts the packages | Rebuild only; `ExampleProjectTests` migrate with the testing model |

All five migrate with the same mechanical recipe (the migration guide in §5). The
load-bearing one — shown in full — is **SearchExamplePackage**, because it exercises every
deleted idiom at once.

### Search example, migrated in full

`SearchEvent.swift` — response cases are deleted; effects re-enter via `modify`:

```swift
import CasePaths

@CasePathable
enum SearchEvent: Equatable {
    case search(SearchQueryEvent)
    case locationTapped(id: String)
}

@CasePathable
enum SearchQueryEvent: Equatable {
    case query(String)
}
```

`SearchState.swift` — **one file replaces three** (`SearchDomainState.swift`,
`SearchViewState.swift`, `SearchViewStateReducer.swift`). `forecastRequestNonce` is deleted:
per-location task replacement makes a newer tap cancel the older forecast request, so the
nonce guard has nothing to guard. The handwritten `SearchListItem`/`SearchListContent` view
types and the reducer (with its `initialViewState(for:)` and identity-preserving
`modify(\.loaded)` dance) collapse into `@Domain` members plus visible computed properties:

```swift
import CasePaths
import IdentifiedCollections
import Lattice

@FeatureState
@CasePathable
enum SearchState: Equatable {
    case noResults
    case results(ResultState)

    @FeatureState
    struct ResultState: Equatable {
        @FeatureState
        struct ResultItem: Equatable, Identifiable {
            @Domain let weatherModel: WeatherSearchDomainModel.Result
            @Domain var forecast: ForecastDomainModel?
            var isLoading = false

            // The row's rendering instructions — previously SearchListItem, rebuilt for
            // every row by the reducer on every commit; now diffed per row, per member.
            var id: String { "\(weatherModel.id)" }
            var name: String { weatherModel.name }
            // Small per-row collection: accepted O(days) compare (plan 05 §8 warns on
            // derived collections; a handful of strings is the accepted shape).
            var forecasts: [String]? {
                guard let forecast else { return nil }
                let daily = forecast.daily
                return zip(daily.time, zip(daily.temperatureMin, daily.temperatureMax))
                    .map { day, temperatures in
                        "\(day.formatted(.dateTime.weekday(.wide))): \(temperatures.0) - \(temperatures.1)"
                    }
            }
        }

        var query: String
        var results: IdentifiedArrayOf<ResultItem>

        static var none: Self {
            ResultState(query: "", results: [])
        }
    }
}
```

`results` moves from `[ResultItem]` to `IdentifiedArrayOf<ResultItem>` so the commit diff is
identity-keyed (plan 05 §6): typing a new query pings list structure once; a forecast landing
on one row fires only that row's changed members.

`WeatherService.swift` — `: Sendable` dropped from the protocol; implementations may now be
main-actor classes:

```swift
protocol WeatherService {
    func searchWeather(query: String) async throws -> WeatherSearchDomainModel
    func forecast(latitude: Double, longitude: Double) async throws -> ForecastDomainModel
}
```

`SearchQueryInteractor.swift` — the clock generic collapses to `any Clock<Duration>` (it only
existed to thread `TestClock` into `Debouncer`); debounce becomes sleep + replacement; the
success/failure response cases become `modify` branches:

```swift
import Lattice

@Interactor<SearchState.ResultState, SearchQueryEvent>
struct SearchQueryInteractor {
    let weatherService: WeatherService
    let clock: any Clock<Duration>
    let debounceDuration: Duration

    init(
        weatherService: WeatherService,
        clock: any Clock<Duration> = ContinuousClock(),
        debounceDuration: Duration = .milliseconds(300)
    ) {
        self.weatherService = weatherService
        self.clock = clock
        self.debounceDuration = debounceDuration
    }

    var body: some InteractorOf<Self> {
        Interact { state, event, effects in
            switch event {
            case .query(let query):
                guard !query.isEmpty else {
                    state = .none
                    return
                }
                state.query = query

                // Every `.query` dispatch replaces the previous in-flight task at this
                // `perform` call site: cancelled sleep = restarted debounce window.
                effects.perform { [weatherService, clock, debounceDuration] effectState in
                    try await clock.sleep(for: debounceDuration)
                    do {
                        let weatherModels = try await weatherService.searchWeather(query: query)
                        try effectState.modify { state in
                            state.results = IdentifiedArray(
                                uniqueElements: weatherModels.results.map { weatherModel in
                                    SearchState.ResultState.ResultItem(
                                        weatherModel: weatherModel,
                                        forecast: nil
                                    )
                                }
                            )
                        }
                    } catch {
                        try effectState.modify { state in
                            state.results = []
                        }
                    }
                }
            }
        }
    }
}
```

`SearchInteractor.swift` — the nonce bookkeeping is gone; the forecast response lands through
`modify` with a plain id re-check (the row can be gone if a new search completes between
launch and re-entry). The `when` composition line is unchanged; the child's `modify`
calls pull back through the `\.results` case lens, and if the state has left `.results` by
then, the write is dropped and the child's tasks are cancelled — the runtime now does what the
nonce used to approximate:

```swift
import Lattice

@Interactor<SearchState, SearchEvent>
struct SearchInteractor {
    private let weatherService: WeatherService
    private let queryInteractor: SearchQueryInteractor

    init(
        weatherService: WeatherService,
        clock: any Clock<Duration> = ContinuousClock(),
        debounceDuration: Duration = .milliseconds(300)
    ) {
        self.weatherService = weatherService
        self.queryInteractor = SearchQueryInteractor(
            weatherService: weatherService,
            clock: clock,
            debounceDuration: debounceDuration
        )
    }

    var body: some InteractorOf<Self> {
        Interact { state, event, effects in
            switch event {
            case .search:
                break

            case .locationTapped(let id):
                guard case .results(var resultState) = state,
                    let tappedModel = resultState.results[id: id]?.weatherModel
                else {
                    return
                }

                for itemID in resultState.results.ids {
                    resultState.results[id: itemID]?.isLoading = false
                }
                resultState.results[id: id]?.isLoading = true
                state = .results(resultState)

                // A newer tap replaces this task (same `perform` call site), so a stale forecast
                // can never overwrite a newer request.
                effects.perform { [weatherService] effectState in
                    guard
                        let forecast = try? await weatherService.forecast(
                            latitude: tappedModel.latitude,
                            longitude: tappedModel.longitude
                        )
                    else { return }
                    try effectState.modify { state in
                        guard case .results(var resultState) = state,
                            resultState.results[id: id] != nil
                        else { return }
                        resultState.results[id: id]?.isLoading = false
                        resultState.results[id: id]?.forecast = forecast
                        state = .results(resultState)
                    }
                }
            }
        }
        .when(state: \.results, action: \.search) {
            queryInteractor
        }
    }
}
```

Deltas worth calling out in the example's README/comments:

- **−2 action cases, −1 state field, −1 generic parameter, −1 type-erasure hop** (the
  `AnyInteractor` erasure existed only to hide the clock generic that existed only for the
  `Debouncer`).
- **−2 files, −5 types.** `SearchViewState.swift` (`SearchViewState`, `SearchListContent`,
  `SearchListItem`, `Weather`) and `SearchViewStateReducer.swift` are deleted outright; the
  visible members of `SearchState` are the view contract, and the reducer's
  identity-preserving `is`/`modify(\.loaded)` merge dance has no successor — diff-at-commit
  needs no identity to preserve.
- View files change mechanically, not structurally: the `switch viewModel.viewState` becomes
  case-accessor projection reads (`if let content = viewModel.results { … }`), row views
  render from `FeatureProjection<SearchState.ResultState.ResultItem>`, the search-field
  binding retargets to the projection (`$viewModel.results.query.sending(\.search.query)` —
  same `sending` shape), and the deleted event enum case disappears from the view.
  `sendViewEvent`/`EventTask` call sites are untouched.
- Package manifests: bump each example package to `swift-tools-version: 6.2` and add the two
  upcoming-feature flags matching the library (plan 01), so the examples compile under the
  same isolation semantics they demonstrate.

Remaining packages migrate by recipe: `TimerLeak`'s `.observe` becomes
`effects.perform { effectState in for await tick in … { try effectState.modify { … } } }`; `Todos`' debounced
auto-sort becomes `clock.sleep` + replacement (dropping its `Debouncer` and clock generic
exactly like Search); `ScopedComposition`'s `.perform`/`.observe` map the same way;
`FineGrained` is a `Sendable`/`.none` strip only.

---

## 4. `specs/` archival & `AGENTS.md`

### Historical design docs

Seven pre-rework docs describe deleted machinery and become historical (they are **not**
rewritten — plans 02–07 in this directory are their successors):

| Doc | Reason |
|---|---|
| `specs/interactors.md` | Specifies `interact(...) -> Emission<Action>`, emission taxonomy, debounce |
| `specs/view-model-event-loop-and-emission-handling.md` | Specifies the emission event loop, buffering, root scopes — all deleted |
| `specs/testing-infrastructure.md` | Specifies the buffered-receive `TestViewModel`/harness model |
| `specs/view-model.md` | Specifies ViewModel as emission executor + reducer host (host role survives; execution model doesn't) |
| `specs/view-state-reducer.md` | Specifies the `ViewStateReducer` protocol/builder/`DefaultValueProvider` layer, deleted whole by plan 05 |
| `specs/observable-state-identity-preserving-merge.md` | Specifies `ObservationStateRegistrar`/`_$id` copy-identity — the machinery plan 05 deletes; diff-at-commit has no identity to preserve |
| `specs/fine-grained-observation.md` | Specifies keyPath-addressed observation built on `@ObservableState` accessors; superseded by the projection + host-registrar design (plan 05) |

Archival note — one line prepended to each of the seven files (and nothing else changed):

```markdown
> **Historical (pre-1.0):** describes the `Emission`/`ViewStateReducer`-era runtime removed in
> the 1.0 Sendable-removal rework; see `specs/sendable-removal/` for the current design.
```

The other three (`enum-case-scoping.md`, `scoped-view-composition.md`, `macros.md`) document
surviving contracts and stay authoritative — with word-level fixes only where trivially wrong
(e.g. `macros.md` rows for the deleted `@ObservableState`/`@ViewStateReducer` macros gain a
"deleted in 1.0, replaced by `@FeatureState`/`@Domain`" cell; incidental `Emission`/`viewState`
mentions in the scoping docs are design-history context, not API docs). `specs/README.md` gets
its runtime-summary paragraph rewritten (it currently opens with "returns `Emission<Action>`")
and a row pointing at `sendable-removal/`.

### `AGENTS.md`

- "Main library concepts": replace the `Interactor`/`Emission`/`Debouncing` bullets with
  `interact(state:action:effects:)`, `Effects` (`perform`/`modify`/`send`/`state`),
  `EffectID`, debounce-by-replacement; replace the `ViewStateReducer`/`ObservableState`
  bullets with `@FeatureState`/`@Domain` (single annotated state type, generated view
  projection, diff-at-commit); the `Feature` bullet narrows to interactor-only bundling;
  replace the Testing bullet
  (`InteractorTestHarness`/`AsyncStreamRecorder` → snapshot-diff `TestViewModel`, `TestClock`).
- Build & Test: drop the `EmissionDebounceTests`/`DebounceInteractorTests` focused commands;
  add the new effect suites from plans 03/04.
- Notes: add "toolchain floor Swift 6.2 / Xcode 26" and keep the podspec/tag rule (it is the
  rule §6 executes).

---

## 5. `MIGRATING-1.0.md` — consumer migration guide (full content)

New file at repo root, linked from the README intro and pasted into the GitHub release notes.
Content below is the deliverable, in full.

````markdown
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
| `Feature(interactor:reducer:)` | `Feature(interactor:)` |
| `viewModel.viewState.someLabel` reads | `viewModel.someLabel` — a generated `@dynamicMemberLookup` projection; `@Domain` members don't compile from views |
| Buffered-receive `TestViewModel` (`send`/`receive` action buffering) | Snapshot-diff `TestViewModel` (`send(_:changes:)` / `expect(changes:)`) |

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
    feature: Feature(interactor: SearchInteractor())
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
    initialState: SearchState(),
    feature: Feature(
        interactor: SearchInteractor(searchClient: SearchClientStub(), clock: clock)
    )
)

model.send(.queryChanged("lattice")) {
    $0.query = "lattice"
    $0.isLoading = true
}

await clock.advance(by: .milliseconds(300))

try model.expect {
    $0.isLoading = false
    $0.results = ["Lattice"]
}
```

Mapping table:

| Old test API | New idiom |
|---|---|
| `send(_:) { … }` | `send(_:changes:)` — unchanged role |
| `receive(action) { … }` for `.perform`/`.observe` output | `expect(changes:)` per `effectState.modify` commit |
| `receive(\.case)` for `effectState.send` re-entry | `receive(\.case, changes:)` — kept, now rare |
| `task.finish()` quiescence | await the task returned from `send`, or `dismount()` at test end |
| `skipReceivedActions()` / `skipInFlightEffects()` | non-exhaustive mode / cancel via `dismount()` |
| `TestClock` + advance | unchanged |
| reducer unit tests / `initialViewState` fixtures | deleted as a category — assert view output by reading the projection (`#expect(model.subtitle == "3 results")`) |

Delete `Sendable` from test fixtures; stubs can be plain classes now.
````

---

## 6. Release mechanics & checklist

Order matters (AGENTS.md: "make sure `Lattice.podspec` has the matching `s.version` first";
skills sync is mtime-based so it runs at edit time, not release time).

1. **Docs/examples merged.** All artifacts in §§1–5 land on main; `swift test` green; the
   ExampleProject workspace builds (open workspace, build the app scheme, or at minimum
   `swift build` each example package).
2. **Skills sync.** `scripts/sync-skills.sh` after the `skills/` edits; commit both `skills/`
   and `.claude/skills/`. Verify no drift: `diff -r skills .claude/skills`.
3. **Dependency prune (deferred from plan 01).** With `Emission`/`Debouncer` gone, check and
   remove now-unused products from `Package.swift` (`AsyncAlgorithms`, `CombineSchedulers` are
   the expected candidates — verify with
   `grep -rn "import AsyncAlgorithms\|import CombineSchedulers" Sources/`) and the matching
   `s.dependency` lines from `Lattice.podspec`. `swift build && swift test` after.
4. **Macro binary.** Nothing to do — never checked in; pod consumers regenerate at
   `pod install` via `prepare_command`, SwiftPM/Xcode consumers build the macro target from
   source (plan 01 §5, plan 08 (c)).
5. **Podspec version.** `s.version = '1.0.0'` (`swift_version = '6.2'` already landed in
   plan 01). Sanity: `pod ipc spec Lattice.podspec`, or `pod lib lint` if CocoaPods is
   available locally.
6. **Commit + tag.** Commit the podspec bump, then tag `1.0.0` (no `v` prefix — matches the
   existing `0.3.1`-style tags and the podspec's `tag: s.version.to_s`). Push tag.
7. **GitHub release** for `1.0.0`: title "Lattice 1.0.0", body = highlights (no-Sendable
   runtime, imperative effects, snapshot testing) + the full `MIGRATING-1.0.md` content +
   toolchain-floor callout (Swift 6.2 / Xcode 26; CocoaPods consumers on older Xcode cannot
   `pod install` this version).
8. **Post-release smoke.** Fresh checkout at the tag: `swift build && swift test`; one example
   package builds against the tag via a path-less package reference if practical (optional).

Release checklist (copy into the release PR description):

```markdown
- [ ] README rewritten (hero example, features, architecture, testing, filters)
- [ ] MIGRATING-1.0.md added and linked from README
- [ ] 5 skills updated; `scripts/sync-skills.sh` run; `diff -r skills .claude/skills` clean
- [ ] ExampleProject: 5 packages + app migrated and building
- [ ] specs: 7 historical docs annotated; specs/README.md summary updated
- [ ] AGENTS.md concepts/commands updated
- [ ] Unused deps pruned from Package.swift + Lattice.podspec (grep-verified)
- [ ] Lattice.podspec s.version = '1.0.0' (swift_version 6.2 already set)
- [ ] `swift build` / `swift test` green (no macro-binary step — consumer-generated)
- [ ] Tag `1.0.0` pushed after podspec commit; GitHub release published with migration guide
```

---

## Acceptance gates

1. **No stale API in living docs.** Zero matches for the deleted vocabulary in every
   non-historical doc:
   ```bash
   grep -rn "Emission\|Debouncer\|\.observe {\|uncheckedSendable\|InteractorTestHarness\|AsyncStreamRecorder\|ViewStateReducer\|ObservableState\|areStatesEqual\|BuildViewState\|DefaultValueProvider" \
     README.md MIGRATING-1.0.md AGENTS.md skills/ ExampleProject/ --include="*.md" --include="*.swift" \
     | grep -v "MIGRATING-1.0.md.*Before\|migration" # before-blocks in the guide are the only allowed hits
   ```
   (Mechanically: the only permitted occurrences are inside explicitly labeled "Before" blocks
   of `MIGRATING-1.0.md` and the seven annotated historical specs.)
2. **Docs compile.** Every full example in README, the two rewritten skills, and
   `MIGRATING-1.0.md` "After" blocks is extracted into a scratch target (or the example
   packages, where they already live) and compiles against the 1.0 library. The README hero
   example and the lattice-skill search example must compile verbatim.
3. **Examples build & behave.** `swift build` in each of the five example packages; the
   workspace app builds; Search example manually verified: keystroke debounce works, tapping
   rows in quick succession shows only the last forecast, clearing the query mid-request shows
   no stale write (the drop contract, observed from the UI).
4. **Skills sync clean.** `scripts/sync-skills.sh` then `diff -r skills .claude/skills` empty.
5. **No Sendable in consumer-facing examples.** `grep -rn "Sendable" skills/ ExampleProject/ --include="*.swift" --include="*.md"`
   returns only the migration guide's "Before" blocks (and any `@concurrent`/`sending`
   escape-hatch discussion, which names the keywords deliberately).
6. **Release integrity.** `Lattice.podspec` `s.version == '1.0.0'` committed **before** the
   `1.0.0` tag exists; tag matches podspec (`git tag --contains $(git log -1 --format=%H -- Lattice.podspec) | grep 1.0.0`);
   GitHub release body contains the migration guide; post-release fresh-checkout smoke passes.
7. **Historical specs annotated, not rewritten.** The seven docs each gain exactly the
   one-line note (diffstat: 7 files, +2 lines each incl. blank line); no other hunks beyond
   the word-level `macros.md` cells called out in §4.

## Risks

- **Plan 07 API drift (top risk).** The testing sections in README, `lattice-testing`, and
  `MIGRATING-1.0.md` are written against the TCA26-`TestStore` shapes the README pins, but
  plan 07 owns final spellings (`expect(changes:)` vs something else, throwing vs async
  assertions), and plan 06 owns the `Feature(interactor:)`/`ViewModel(initialState:feature:)`
  construction spelling used throughout. Mitigation: this workstream lands *after* plans 06
  and 07; a doc-sync check against the actual surfaces is part of gate 2 (compiling examples
  catches every drift).
- **Docs-say / code-does divergence in prose.** Compiling examples (gate 2) doesn't catch
  wrong *prose* (e.g. claiming `modify` throws on scope departure — it doesn't, it drops).
  Mitigation: the semantic claims in §5 are lifted verbatim from plans 03/04; reviewer
  checklist item to diff prose claims against those plans.
- **Example-package toolchain floor.** Bumping example manifests to 6.2 + upcoming features
  may surface isolation diagnostics in example-only code paths not covered by library tests.
  Mitigation: examples are small; fix-forward, and they're gate 3 anyway.
- **`pod lib lint` availability.** Full lint may not run locally (prepare_command builds the
  macro with the local toolchain). Minimum bar is `pod ipc spec` syntax validation plus the
  plan-01 flag greps; a failed remote `pod install` after release is recoverable with a
  podspec-only patch tag.
- **Search-example behavior change.** Replacing the forecast nonce with task auto-replacement
  changes semantics subtly: previously a stale response was *ignored on arrival*; now the
  stale *request* is cancelled at launch of the newer one. Net user-visible behavior is
  equivalent-or-better, but the manual verification in gate 3 exists because no unit test
  covers the app-level wiring.
- **README hero example length.** A full feature (client, state, interactor, view)
  is long for a README. Accepted: it is the single canonical demonstration of the new runtime
  and is reused by the skills; the Quick Start counter stays short for the skim path.
