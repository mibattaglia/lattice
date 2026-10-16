# Enum-Case Scoping (Spec C): case-scoped `ScopedViewModel` projections

Status: ✅ Implemented — depends on
[`scoped-view-composition.md`](./scoped-view-composition.md) (Spec B), which in turn depends on
[`fine-grained-observation.md`](./fine-grained-observation.md) (Spec A, ✅) and
[`observable-state-identity-preserving-merge.md`](./observable-state-identity-preserving-merge.md)
(✅). Included one small **prerequisite fix** to enum `_$id` generation.

## Problem

Spec B's `scope(state:action:)` takes a key path to a child state. Enum cases are not reachable
by key path, so a feature whose state is (or contains) an enum cannot project a case's payload
into a `ScopedViewModel` with Spec B's overloads:

```swift
@CasePathable
@FeatureState
enum PhaseState: Equatable, Sendable {
    case loading
    case success(SuccessState)   // SuccessState is @FeatureState
}
```

The case is reachable through a case key path of the generated mirror instead: `@FeatureState`
carries `@CasePathable` onto `PhaseState.ViewState`, whose `\.success` is a
`CaseKeyPath<PhaseState.ViewState, SuccessState.ViewState>`.

### The two regimes (and the silent trap between them)

Without case scoping, views compose enum state by switching over the coarse read and handing
the destructured payload to a child view. Whether that is correct depends entirely on how the
interactor writes the state:

- **Extraction + wholesale replacement — correct, coarse.** If the interactor always replaces
  the case (`state = .success(SuccessState(...))`), every payload change mints a new payload
  `_$id`, which changes the root `_$id` (payload id + case tag), which fires the gated coarse
  `\.state`, which re-renders the `switch`, which re-extracts a fresh payload. Snapshots are
  re-taken on every change and are never stale. The cost is granularity: the whole `switch`
  subtree re-renders on any payload change.
- **Scope + in-place mutation — correct, fine-grained.** If the interactor mutates the payload
  through the case (`Interactors.When(state: \.success, action: \.success)`, or
  `state.modify(\.success) { $0.title = ... }`), only the payload's own registrar leaves fire;
  the root `_$id` is untouched and the `switch` does not re-render. Precision requires a
  **live** read handle — which extraction cannot provide.
- **Mixing them is the trap.** An extracted payload copy shares the live payload's registrar,
  so an in-place leaf mutation *invalidates* a child view rendering from the copy — but the
  copy's stored values are a snapshot, and because the coarse fire never happens, the `switch`
  never re-extracts. The child re-renders **with stale data**, silently and persistently.

The rule this spec establishes and documents: **extraction pairs with wholesale replacement;
scope pairs with in-place mutation; never mix.** Existing switch-and-extract code remains valid
at coarse granularity; case scoping is what unlocks the fine-grained regime (and decouples the
child view from the parent feature type, per Spec B). A `switch` whose own `body` reads the
payload's members (`case .success(let success): Text(success.title)`) is not extraction in this
sense: those reads register on the payload's registrars and re-run the same `body`, which
re-extracts (`switchOverViewStateTracksTheCaseAndThePayloadMembersItRead`).

## Prerequisite fix: stable `_$id` for payload-less enum cases

The enum expansion originally generated, for a payload-less case:

```swift
case .loading:
return ObservableStateID()._$tag(0)
```

`ObservableStateID()` mints a **fresh UUID on every access**, so two evaluations of
`PhaseState.loading._$id` were never equal. While a payload-less case was active at the root, the
view model's coarse-fire gate (Spec A, in the commit step) computed `oldID != newID` on **every
commit**, firing the coarse key path even when nothing changed. Spec A's fine-grained gating
silently degraded to the pre-Spec-A behavior until the state left that case — and this spec's
`switch`-driven design leans directly on "the switch only re-renders on real case changes," so
the fix landed here.

### Source

[`FeatureState.swift`](../Sources/Lattice/Observation/FeatureState.swift) — a shared inert
identity:

```swift
/// A shared identity for values that carry no observable content of their own, such as
/// payloadless enum cases. Tagging `_$inert` with a case index yields an id that is stable
/// across accesses and distinct across cases.
public static let _$inert = Self()
```

[`FeatureStateMacro.swift`](../Sources/LatticeMacros/Plugins/FeatureStateMacro.swift) —
`FeatureStateCase.getCase` generates, for a payload-less case:

```swift
case .loading:
    return ObservableStateID._$inert._$tag(0)
```

### Deliberately unchanged: single non-`FeatureState` payloads

`ObservableStateID._$id(for:)`'s fallback (`?? Self()`) stays as-is, so a case like
`.error(String)` keeps an **unstable** `_$id`. That instability is load-bearing: a `String`
payload has no registrar, so the coarse root fire is the *only* channel by which
`.error("a") → .error("b")` re-renders the `switch`. Stabilizing it would make such content
changes invisible to observation. The precision model is therefore:

- payload-less case active → no coarse fire on unrelated commits (this fix);
- `@FeatureState` payload → fine-grained via the payload registrar; coarse fires only on a real
  case change or a wholesale payload replacement;
- single non-`FeatureState` payload → coarse fire on every commit that changes the payload's
  content while the case is active, and on every commit when the feature has no
  `areStatesEqual` (intended; give the payload `@FeatureState` structure if this matters).

Known gap: a case with several payload values (`.failed(message:retryCount:)`) shares the
payload-less branch of `getCase`, so it returns the `_$inert` tag and never fires the root on a
content change; see [FeatureState](./feature-state.md#limitations).

### Regression tests

- `EnumCaseScopingTests.payloadlessCaseReassignmentDoesNotFireCoarse`: reassigning the active
  payload-less case, without a state equality to swallow it, does not fire a whole-`viewState`
  observer and keeps the root `_$id`.
- `EnumCaseScopingTests.enumCaseSwitchFiresRoot` and
  `EnumRootObservationTests.caseChangeInvalidatesWholeStateObserver`: a case change
  (`.loading → .success`) still fires.

## Goal

```swift
struct PhaseView: View {
    @State var viewModel: ViewModel<PhaseFeature>
    var body: some View {
        switch viewModel.viewState {                 // coarse read: re-renders on case change only
        case .loading:
            LoadingView()
        case .success:
            SuccessView(model: viewModel.scope(state: \.success, action: \.success))
        }
    }
}

struct SuccessView: View {
    let model: ScopedViewModel<SuccessState, SuccessAction>
    var body: some View {
        Text(model.title)                            // fine-grained read on the payload registrar
        TextField("Title", text: model.binding(\.title, sending: \.titleChanged))
    }
}
```

A normal, exhaustive Swift `switch` selects the case; `scope` makes the matched payload live
and embeds its actions. No wrapper views, no `if let` noise inside an already-matched case, no
fallback arguments at the call site.

## Design

Two forms, both returning Spec B's `ScopedViewModel`:

- **`scope(state:action:)` (trapping)** — the switch-facing form. Traps with
  `fatalError` if the case is not active at creation. This is safe by construction in
  the intended pattern: SwiftUI body evaluation is synchronous on the main actor, so nothing
  can flip the state between `case .success:` matching and the `scope` call in the same body.
  The trap fires only on genuine misuse (scoping into a case you did not just match), like an
  out-of-bounds `Array` subscript — the precondition is locally verifiable at the call site.
- **`scopeIfActive(state:action:)` (optional)** — the primitive the trapping form is sugar
  over. For `if let` layouts where a case renders or nothing does. The two forms have distinct
  base names (rather than overloading on optionality of the return type) so that call sites
  without type context are never ambiguous and the semantics are visible in the spelling.

### Staleness: implicit creation-snapshot fallback

The scope's state closure re-reads through the parent on every access, so values are always
live while the case is active. If the case flips between a send and the next render pass, the
extraction returns `nil` for at most one transitional window before the `switch` (which is
registered on the coarse key path) re-renders and tears the child down. In that window the scope
serves the payload captured at scope creation:

```swift
state: { [self] in Child.ViewState(self._state())[case: casePath]?._state ?? snapshot }
```

The fallback is an implementation detail, not API surface. During normal rendering SwiftUI
re-evaluates the `switch` before its children, so the dead child is discarded without reading;
the window that matters in practice is binding getters called between a case-flipping send and
the next render pass. Because the scope is recreated every render, the creation snapshot is
also the last-render value — no cache maintenance needed. (TCA 2.0's `IfCaseLetCore` reaches
the same design with an actively maintained `cachedState` tombstone; statelessness lets us get
it for free.)

### Late sends

A child can send after its case flipped (`.success(.retry)` arriving while state is
`.loading`). The scope does not police this — there is no dismount lifecycle to track. The
interactor is the arbiter, as it already is for every action: `Interactors.When` over a case
path drops child actions while the case is inactive, and a hand-written interactor switches on
`(state, action)` and drops actions that no longer apply. This is documented on the API rather
than enforced with runtime machinery.

## API

All overloads live in
[`ScopedViewModel.swift`](../Sources/Lattice/Presentation/ViewModel/ScopedViewModel.swift),
inside its `#if canImport(CasePaths)` block:

```swift
extension ViewModel where State.ViewState: CasePathable, Action: CasePathable {
    /// Enum state: projects the active case's payload, `nil` otherwise.
    public func scopeIfActive<P: ViewStateProjection, ChildAction>(
        state casePath: CaseKeyPath<State.ViewState, P>,
        action embed: CaseKeyPath<Action, ChildAction>
    ) -> ScopedViewModel<P.State, ChildAction>?

    /// Trapping form for use inside a matched `switch viewModel.viewState` case.
    public func scope<P: ViewStateProjection, ChildAction>(
        state casePath: CaseKeyPath<State.ViewState, P>,
        action embed: CaseKeyPath<Action, ChildAction>,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> ScopedViewModel<P.State, ChildAction>
}

extension ScopedViewModel where Child.ViewState: CasePathable, ChildAction: CasePathable {
    // The same two overloads over `CaseKeyPath<Child.ViewState, P>`, for an enum child.
}
```

- The case path is rooted at the `@CasePathable` mirror and names the payload's projection `P`;
  the scope recovers the raw payload as `P.State` through the SPI `_state`. Case scoping
  therefore requires the state enum to be `@CasePathable` (user-applied; `@FeatureState`
  propagates it to the mirror) and the payload to be `@FeatureState`. A plain payload has no
  projection, so it is read or bound through the mirror but not scoped.
- The trapping form reports the call site and the case path in its `fatalError` message.
- The raw-enum overload, `scopeIfActive(state: CaseKeyPath<State, Child>, …)`, is removed:
  coexisting with the mirror overload made `\.success` ambiguous, and the raw state is not a
  view-facing type. The negative compile checks (`LEAK_CASE`) assert that a raw-enum case path
  is rejected, and that a `@Domain` member of a payload is rejected through a case scope and a
  case binding.
- There is no ambiguity with Spec B's key-path `scope`: the mirror is not
  `@dynamicMemberLookup`, so for an enum state `\.success` can only be a case key path, and a
  struct state has no case key paths.

No changes to the runtime, `ScopedViewModel`'s stored representation, or Spec B's existing
overloads were needed.

### Observation trace (why this is fine-grained)

Reading `model.title` through a case scope registers: the coarse `\.state` (gated on root
`_$id` — fires only on a case change or wholesale payload replacement, exactly when the child
should die or fully refresh) and `\.title` on the payload's own registrar (fires on in-place
mutation). The `switch` view registers only the coarse key path (plus any payload member it
reads itself). So: in-place payload mutation re-renders only the leaf child; a case change
re-renders the `switch`, which tears down the child and builds the new case's subtree. For a
nested enum child (`scope(state: \.phase, action: \.phase)` per Spec B, then case-scoping the
result), the containing registrar's `\.phase` fires on case changes via `didModify` identity
comparison — same shape, one level down.

## Tests

`Tests/LatticeTests/PresentationTests/EnumCaseScopingTests.swift` covers root observation
(`payloadlessCaseReassignmentDoesNotFireCoarse`, `enumCaseSwitchFiresRoot`,
`payloadEditThroughWhenCasePathIsLeafOnlyAndKeepsRootID`,
`switchOverViewStateTracksTheCaseAndThePayloadMembersItRead`), case scoping
(`trappingScopeReadsLivePayload`, `scopeIfActiveReturnsNilForInactiveCase`,
`caseFlipServesCreationSnapshotWithoutCrashing`, `lateSendAfterCaseFlipIsDroppedByWhen`,
`bindingThroughCaseScope`) and an enum child of a scope
(`scopedEnumChildScopesIntoItsActiveCase`, `enumChildCaseSwitchFiresItsCoarseReadButNotTheRoot`).
Excerpt:

```swift
@FeatureState struct SuccessState: Equatable, Sendable {
    var title: String
    var count: Int
}

// Mocks/PhaseState.swift — a `@FeatureState` enum must be alone in its file.
@CasePathable
@FeatureState
enum PhaseState: Equatable, Sendable {
    case loading
    case success(SuccessState)
}

/// Transitions replace the case; steady-state updates mutate the payload in place through
/// `Interactors.When`'s case path, which also drops payload actions while the case is inactive.
@Interactor<PhaseState, PhaseAction>
private struct PhaseInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interactors.When(state: \.success, action: \.success) {
            SuccessInteractor()
        }
        Interact { state, action in
            switch action {
            case .load: state = .success(SuccessState(title: "t", count: 0))
            case .reset: state = .loading
            case .tick:
                // Reassigns the payload-less case the state is already in.
                if case .loading = state { state = .loading }
            case .success: break
            }
        }
    }
}

@MainActor
@Suite struct EnumCaseScopingTests {
    // … makeViewModel(areStatesEqual:)

    @Test func payloadEditThroughWhenCasePathIsLeafOnlyAndKeepsRootID() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let rootID = vm.state._$id
        let success = vm.scope(state: \.success, action: \.success)

        let title = ObservationProbe { _ = success.title }
        let count = ObservationProbe { _ = success.count }
        let root = ObservationProbe { _ = vm.viewState }

        success.sendViewEvent(.incremented)  // in place: only count changes
        #expect(count.didFire)
        #expect(!title.didFire)  // sibling leaf not invalidated
        #expect(!root.didFire)  // switch not re-rendered
        #expect(vm.state._$id == rootID)
        #expect(success.count == 1)
    }

    @Test func caseFlipServesCreationSnapshotWithoutCrashing() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)

        vm.sendViewEvent(.reset)  // .success -> .loading; scope is now stale
        #expect(success.title == "t")  // creation snapshot, no trap/crash
    }
}
```

The trapping path itself is not unit-tested (no exit-test infrastructure in the suite); the
optional primitive's `nil` path covers the branch, and the trap is a `fatalError` whose
condition is pinned by `scopeIfActiveReturnsNilForInactiveCase`.

## Demo project

The `ExampleProject/ScopedCompositionExamplePackage` from Spec B's Demo project section has a
second screen for this spec: `PhaseExampleAppView` (the `case enumCaseScoping` entry of
`ContentView.swift`'s `Example` enum, "Enum Case Scoping Example"), which builds the `Feature` and
`ViewModel` in `@State` with `initialState: .loading`.

The demo makes four things visible in a running app: the fine-grained in-place path through a
case scope (down a deep chain of nested children), the coarse case-change path at both enum
levels, and the `_$inert` fix.

The whole state is the enum, and the success payload is a deep chain of nested `@FeatureState`
children (`Success > Session > Telemetry > Subphase > Active`) with a `Summary` sibling branch at
the first level and a nested sub-phase **enum** at the third, so the render counters can show
exactly which boundaries a change crosses:

```swift
// PhaseState.swift, alone in its file
@CasePathable
@FeatureState
enum PhaseState: Equatable {
    case loading
    case success(SuccessState)
}

// SubphaseState.swift, alone in its file
@CasePathable
@FeatureState
enum SubphaseState: Equatable {
    case idle
    case active(ActiveState)
}

// SuccessState.swift
@FeatureState
struct SuccessState: Equatable {
    var title = "Success"
    var summary = SummaryState()  // sibling branch: count
    var session = SessionState()  // deep branch: name > telemetry
}

@FeatureState
struct SessionState: Equatable {
    var name = "Live sync"
    var telemetry = TelemetryState()
}

@FeatureState
struct TelemetryState: Equatable {
    var status = "Connected"
    var subphase: SubphaseState = .idle
}

@FeatureState
struct ActiveState: Equatable {  // the deep leaf
    var tick = 0
    var note = ""
}
```

`SummaryState` holds `count`. Each enum sits alone in its file, as the Swift 6.4 layout rule in
[FeatureState](./feature-state.md#limitations) requires, and the payload structs share
`SuccessState.swift`.

Each level is rendered by a thin child view holding a `ScopedViewModel` chained with Spec B's
key-path `scope` from the case scope; the inner sub-phase is case-scoped through
`ScopedViewModel`'s case overload
(`model.scope(state: \.subphase, action: \.subphase).scope(state: \.active, action: \.active)`),
demonstrating case scoping below the root. The action enums nest the same way
(`ActiveAction ⊂ SubphaseAction ⊂ TelemetryAction ⊂ SessionAction ⊂ SuccessAction ⊂
PhaseEvent`, with `SummaryAction` as the sibling branch).

`PhaseInteractor` keeps this spec's two-regimes discipline at **both** enum levels: it mutates
payloads in place while staying in a case and replaces a case only on a real transition.
Because the state is the enum itself, each case carries its own data:

- `.loadTapped` fakes an async load: an effect that sleeps for the load duration on the
  interactor's injected clock (one second in the app), then moves
  `.loading → .success(SuccessState())` with `effects.modify` and leaves any other case alone.
  Tapping Load again auto-cancels the waiting load, so the success case comes a full delay after
  the last tap. `.resetTapped` returns to `.loading`, dropping the payload, so the next Load
  begins from the defaults.
- `.startTicking` starts a once-per-second ticker: an effect that loops over
  `try await clock.sleep(for:)` and `try effects.modify(tick)`. The root view's `.task` sends it
  and forwards its own cancellation to the returned task, so the ticker stops with the view.
  There is no start-once guard: re-sending `.startTicking` auto-cancels the running ticker, so a
  re-appearing view never runs two.
- Each tick increments `tick` only while `.active` is showing, so `Tick:` counts the ticks since
  Start. While a payload-less case (`.loading` or `.idle`) is showing, a tick changes nothing.
- `.success(.session(.telemetry(.startTapped)))` moves `.idle → .active(ActiveState())`;
  `.stopTapped` returns to `.idle`, dropping the payload, so the next Start begins from the
  defaults.
- `.success(...)` actions are dropped while the state is not `.success` (the late-send
  discipline from "Late sends"), and the note edit is dropped while the sub-phase is not
  `.active`.

The root view is a plain exhaustive `switch` over `viewModel.viewState`, with load/reset
buttons outside the switch and a render counter on **every** view in the chain. The view tree
mirrors the state tree:

- `PhaseExampleView` — owns the outer `switch`; `.success` renders
  `SuccessView(model: viewModel.scope(state: \.success, action: \.success))`; starts the ticker
  from `.task` and cancels it when the view goes away.
- `SuccessView` — title `TextField` via `binding(\.title, sending: \.titleChanged)`;
  `SummaryView(model: model.scope(state: \.summary, action: \.summary))` (sibling branch) and
  `SessionView(model: model.scope(state: \.session, action: \.session))`.
- `SummaryView` — count + Increment button.
- `SessionView` — reads `name`, scopes deeper to `TelemetryView`.
- `TelemetryView` — reads `status`; owns the **inner** `switch` over `model.subphase` (reading
  the sub-phase registers its identity, so this view re-renders on inner case changes only);
  `.active` renders `ActiveView` via the chained case scope shown above; Start/Stop buttons
  drive the sub-phase.
- `ActiveView` — the deep leaf: `Tick:` text and a note `TextField` via
  `binding(\.note, sending: \.noteChanged)`.

Expected, demonstrable behavior (all visible in the render counters):

- Ticks while `.active` is showing, or typing in the **Note** field (in-place mutations of the
  deep leaf): only `ActiveView renders:` advances. Every intermediate counter (`TelemetryView`,
  `SessionView`, `SuccessView`) and the sibling (`SummaryView`) stay put, as does the root
  switch.
- Tapping **Increment** (sibling branch): only `SummaryView renders:` advances.
- Tapping **Start**/**Stop** (inner case change): `TelemetryView renders:` advances — the
  sub-phase identity changed, so the inner switch re-renders and builds or tears down the
  `ActiveView` subtree. `SessionView` and everything above stay put.
- Tapping **Load**/**Reset** (outer case change): `PhaseExampleView renders:` advances — the
  root `_$id` changed, the coarse fire re-renders the outer switch, and the success subtree is
  built or torn down. This is the intended coarse channel, not a regression.
- While `.loading` is showing, the ticker keeps committing once per second and **no**
  counter advances: a tick changes only the `.active` payload, and `.loading` keeps its
  `_$inert`-stable identity across commits, so a commit that leaves `.loading` showing never
  counts as a wholesale replacement. This is the `_$inert` fix made visible. The same holds one
  level down while the sub-phase sits in `.idle`.

Each counter lives in its view value (`private final class Renders`), so it starts over when
SwiftUI re-creates that view (for example `ActiveView` after Start); compare which counters
advance rather than absolute counts.

`PhaseExampleTests` runs the feature under `TestModel`, driving the load and the ticker on an
`EffectClock`: `resetAndStopReturnToDefaultPayloadsAndLateSendsAreDropped` (a walk-through),
`loadShowsTheSuccessCaseAFullDelayAfterTheLastTap`, `ticksWhileLoadingChangeNothing`,
`ticksCountOnlyWhileActiveUntilTheTickerIsCancelled` and
`startingTheTickerAgainReplacesTheRunningOne`. The boundaries the counters show are proven in the
library's suites, among them `EnumCaseScopingTests.payloadlessCaseReassignmentDoesNotFireCoarse`
(ticks while `.loading`), `payloadEditThroughWhenCasePathIsLeafOnlyAndKeepsRootID` and
`ViewModelObservationTests.casePathMutationDoesNotInvalidateWholePhaseObservation` (leaf edits),
`EnumCaseScopingTests.enumChildCaseSwitchFiresItsCoarseReadButNotTheRoot` (Start's inner case
change), and `enumCaseSwitchFiresRoot` and
`switchOverViewStateTracksTheCaseAndThePayloadMembersItRead` (Load/Reset).

## Validation

1. `swift build`
2. `swift test --filter FeatureStateMacroTests` — the enum expansion snapshots, including
   payload-less cases.
3. `swift test --filter EnumCaseScopingTests`
4. `swift test --filter EnumRootObservationTests` and
   `swift test --filter FineGrainedObservationTests` — Spec A behavior unchanged (case changes
   still fire coarse).
5. `swift test --filter ScopedViewModelTests` — Spec B unchanged.
6. `cd ExampleProject/ScopedCompositionExamplePackage && swift test --filter PhaseExampleTests`,
   then confirm in the running demo, with the render counters plus `Self._printChanges()`, that
   the expected behaviors listed there hold: in-place mutations re-render only the deep leaf,
   load/reset (case change) re-renders the outer `switch`, and ticks while in `.loading`
   re-render nothing (the `_$inert` fix).
7. `swift test` — full suite.

## Migration / API notes

- Existing switch-and-extract code keeps working under the wholesale-replacement regime (coarse
  granularity); case scoping adds the fine-grained path.
- Document the two-regimes rule prominently (this spec's Problem section is the source of
  truth): extraction pairs with wholesale replacement; scope pairs with in-place mutation;
  mixing them shows stale data.
- Requires the state enum to be `@CasePathable` (user-applied; `@FeatureState` propagates it to
  the `ViewState` mirror) and the payload to be `@FeatureState`.
- Payload-less cases need no scope: no state to project, and one-off actions are a plain
  `viewModel.sendViewEvent(...)` closure or Spec B's typed-callback handoff.
- Give enum payloads `@FeatureState` structure when their content changes matter for
  precision; a plain payload (e.g. `.error(String)`) is observed coarsely by design (see the
  prerequisite-fix section).
- Enum case bindings (`$viewModel.loaded.query.sending(...)`) go through the same mirror, for
  both payload kinds.
- Declare each `@FeatureState` enum in its own file until the Swift 6.4 compiler crash is fixed
  (see [FeatureState](./feature-state.md#limitations)).

## Out of scope

- A macro-generated case enumeration (an enum of pre-scoped `ScopedViewModel`s enabling
  `switch vm.cases { case .success(let model): ... }`). Requires a state-case ↔ action-case
  pairing convention Lattice does not have.
- Presentation-driving bindings (`Binding<Bool>`/`Binding<Item?>` for sheets/navigation from
  case state). Lattice has no navigation machinery; revisit if it grows one.
- Runtime rejection of late sends (a TCA-style dismount check). The interactor already owns
  `(state, action)` validity; adding scope-side lifecycle would reintroduce exactly the
  statefulness Spec B's design avoids.
- Direct-state-write bindings (TCA 2.0's `$store.member` writing through the store without an
  action). Deliberately rejected: Lattice keeps all mutations flowing through the interactor.
