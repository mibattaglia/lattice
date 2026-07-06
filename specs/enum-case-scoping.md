# Enum-Case Scoping (Spec C): case-scoped `ScopedViewModel` projections

Status: 🔧 Proposed — depends on
[`scoped-view-composition.md`](./scoped-view-composition.md) (Spec B) landing first, which in
turn depends on [`fine-grained-observation.md`](./fine-grained-observation.md) (Spec A, ✅) and
[`observable-state-identity-preserving-merge.md`](./observable-state-identity-preserving-merge.md)
(✅). Includes one small **prerequisite fix** to enum `_$id` generation (macro change — requires
`scripts/rebuild-macro.sh`).

## Problem

Spec B's `scope(state:action:)` requires a `KeyPath<ViewState, ChildState>` to a non-optional
`@ObservableState` slice. Enum cases are not reachable by key path, so a feature whose view
state is (or contains) an enum cannot project a case's payload into a `ScopedViewModel`:

```swift
@CasePathable
@ObservableState
enum PhaseViewState: Equatable, Sendable {
    case loading
    case success(SuccessViewState)   // SuccessViewState is @ObservableState
}
```

`@CasePathable`'s dynamic-member key path (`\.success`) lands on `SuccessViewState?`, which
does not conform to `ObservableState` (Lattice has no `Optional: ObservableState` conformance),
so neither Spec B overload applies.

### The two regimes (and the silent trap between them)

Without new API, views compose enum state by switching over the coarse read and destructuring
the payload. Whether that is correct depends entirely on reducer style:

- **Extraction + wholesale rebuild — correct, coarse.** If the reducer always rebuilds the
  case (`v = .success(SuccessViewState(...))`), every payload change mints a new payload `_$id`,
  which changes the root `_$id` (payload id + case tag), which fires the gated coarse
  `\.viewState`, which re-renders the `switch`, which re-extracts a fresh payload. Snapshots
  are re-taken on every change and are never stale. The cost is granularity: the whole `switch`
  subtree re-renders on any payload change.
- **Scope + in-place mutation — correct, fine-grained.** If the reducer mutates the payload
  through the case (`v.modify(\.success) { $0.title = ... }`), only the payload's own
  registrar leaves fire; the root `_$id` is untouched and the `switch` does not re-render.
  Precision requires a **live** read handle — which extraction cannot provide.
- **Mixing them is the trap.** An extracted payload copy shares the live payload's registrar,
  so an in-place leaf mutation *invalidates* a child view rendering from the copy — but the
  copy's stored values are a snapshot, and because the coarse fire never happens, the `switch`
  never re-extracts. The child re-renders **with stale data**, silently and persistently.

The rule this spec establishes and documents: **extraction pairs with wholesale rebuild; scope
pairs with in-place mutation; never mix.** Existing switch-and-extract code remains valid at
coarse granularity; case scoping is what unlocks the fine-grained regime (and decouples the
child view from the parent feature type, per Spec B).

## Prerequisite fix: stable `_$id` for payloadless enum cases

`enumExpansion` currently generates, for a payloadless case:

```swift
case .loading:
return ObservableStateID()._$tag(0)
```

`ObservableStateID()` mints a **fresh UUID on every access**, so two evaluations of
`PhaseViewState.loading._$id` are never equal. Consequence: while a payloadless case is active
at the root, the `ViewModel._modify` gate (Spec A) computes `oldID != newID` on **every reduce
that runs**, firing the coarse `\.viewState` even when nothing changed. Spec A's fine-grained
gating silently degrades to the pre-Spec-A behavior until the state leaves that case — and this
spec's `switch`-driven design leans directly on "the switch only re-renders on real case
changes," so the fix lands here.

### Source changes

`Sources/Lattice/Observation/ObservableState.swift` — a shared inert identity:

```swift
extension ObservableStateID {
    /// A shared identity for values that carry no observable content of their own, such as
    /// payloadless enum cases. Tagging `_$inert` with a case index yields an id that is stable
    /// across accesses and distinct across cases.
    public static let _$inert = Self()
}
```

`Sources/LatticeMacros/Plugins/Derived/ObservableStateMacro.swift` — `ObservableStateCase.getCase`,
payloadless branch only:

```diff
     case .\(element.name.text):
-    return ObservableStateID()._$tag(\(tag))
+    return ObservableStateID._$inert._$tag(\(tag))
```

This is a macro-source change: run `scripts/rebuild-macro.sh` to refresh the checked-in
`Macros/LatticeMacros` binary, and update any `LatticeMacrosTests` expansion snapshots that
cover payloadless enum cases.

### Deliberately unchanged: cases with non-`ObservableState` payloads

`ObservableStateID._$id(for:)`'s fallback (`?? Self()`) stays as-is, so a case like
`.error(String)` keeps an **unstable** `_$id`. That instability is load-bearing: a `String`
payload has no registrar, so the coarse root fire is the *only* channel by which
`.error("a") → .error("b")` re-renders the `switch`. Stabilizing it would make such content
changes invisible to observation. The precision model is therefore:

- payloadless case active → no coarse fire on unrelated reduces (this fix);
- `@ObservableState` payload → fine-grained via the payload registrar; coarse fires only on a
  real case change or wholesale payload rebuild;
- non-`ObservableState` payload → coarse fire on every reduce while active (intended; give the
  payload `@ObservableState` structure if this matters).

### Regression tests

In the new test file (see Tests below):

- payloadless case active at the root + a reduce that changes unrelated domain state → a
  whole-`viewState` observer does **not** fire (fails before the fix);
- case change (`.loading → .success`) → the observer **does** fire (pins Spec A's
  `EnumRootObservationTests` behavior against this change).

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
    let model: ScopedViewModel<SuccessViewState, SuccessAction>
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

Two forms, both returning the existing `ScopedViewModel` from Spec B:

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

The scope's `_state()` re-reads through the parent on every access (`viewState[case:]`), so
values are always live while the case is active. If the case flips between a send and the next
render pass, `[case:]` returns `nil` for at most one transitional window before the `switch`
(which is registered on the coarse key path) re-renders and tears the child down. In that
window `_state()` serves the payload captured at scope creation:

```swift
state: { viewState[case: casePath] ?? snapshotAtCreation }
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
interactor is the arbiter, as it already is for every action: switch on `(state, action)` and
drop actions that no longer apply. This is documented on the API rather than enforced with
runtime machinery.

## Source changes

All additions live in `Sources/Lattice/Presentation/ViewModel/ScopedViewModel.swift` (Spec B's
file), inside the existing `#if canImport(CasePaths)` block. Case scoping requires the enum to
be `@CasePathable` in addition to `@ObservableState` (the `@ObservableState` macro does not add
case paths).

```swift
extension ViewModel where ViewState: CasePathable, Action: CasePathable {
    /// Projects this view model onto the payload of an enum case of view state, if that case
    /// is currently active.
    ///
    /// This is the primitive form; ``scope(state:action:fileID:line:)`` is trapping sugar over
    /// it for use inside a matched `switch` case. Reads are live: the returned scope
    /// re-extracts the payload from the current view state on every access, so in-place payload
    /// mutations are observed fine-grained. If the case deactivates while the scope is still
    /// held (at most one transitional render), reads serve the payload captured at creation.
    ///
    /// Sends are embedded into this feature's action with `embed` and run on this view model's
    /// action loop. A send can arrive after the case has deactivated; the interactor should
    /// drop actions that no longer apply to the current state.
    ///
    /// - Parameters:
    ///   - casePath: A case key path to an `@ObservableState` payload of the view state enum.
    ///   - embed: A case key path that embeds the child action into this feature's action.
    /// - Returns: A scope over the case's payload, or `nil` if the case is not active.
    public func scopeIfActive<Child: ObservableState, ChildAction: Sendable>(
        state casePath: CaseKeyPath<ViewState, Child>,
        action embed: CaseKeyPath<Action, ChildAction>
    ) -> ScopedViewModel<Child, ChildAction>? {
        guard let snapshot = self.viewState[case: casePath] else { return nil }
        return ScopedViewModel(
            state: { [self] in self.viewState[case: casePath] ?? snapshot },
            send: { [self] childAction in self.sendViewEvent(embed(childAction)) }
        )
    }

    /// Projects this view model onto the payload of the currently active enum case of view
    /// state, trapping if the case is not active.
    ///
    /// Call this only inside a `switch` case that just matched the same case:
    ///
    /// ```swift
    /// switch viewModel.viewState {
    /// case .loading:
    ///     LoadingView()
    /// case .success:
    ///     SuccessView(model: viewModel.scope(state: \.success, action: \.success))
    /// }
    /// ```
    ///
    /// Body evaluation is synchronous on the main actor, so within a matched case this cannot
    /// trap. Use ``scopeIfActive(state:action:)`` when the case may legitimately be inactive.
    public func scope<Child: ObservableState, ChildAction: Sendable>(
        state casePath: CaseKeyPath<ViewState, Child>,
        action embed: CaseKeyPath<Action, ChildAction>,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> ScopedViewModel<Child, ChildAction> {
        guard let scoped = scopeIfActive(state: casePath, action: embed) else {
            fatalError(
                """
                scope(state:action:) at \(fileID):\(line): scoped into case '\(casePath)' \
                while it is not the active case of the view state. Call this only inside a \
                switch case that matched the same case, or use scopeIfActive(state:action:).
                """
            )
        }
        return scoped
    }
}

extension ScopedViewModel where ChildState: CasePathable {
    /// Projects this scope onto the payload of an enum case of the child slice, if active.
    /// See ``ViewModel/scopeIfActive(state:action:)``.
    public func scopeIfActive<CaseState: ObservableState, CaseAction: Sendable>(
        state casePath: CaseKeyPath<ChildState, CaseState>,
        action embed: CaseKeyPath<ChildAction, CaseAction>
    ) -> ScopedViewModel<CaseState, CaseAction>? {
        guard let snapshot = _state()[case: casePath] else { return nil }
        let state = self._state
        let send = self._send
        return ScopedViewModel<CaseState, CaseAction>(
            state: { state()[case: casePath] ?? snapshot },
            send: { caseAction in send(embed(caseAction)) }
        )
    }

    /// Projects this scope onto the payload of the currently active enum case of the child
    /// slice, trapping if the case is not active. See ``ViewModel/scope(state:action:fileID:line:)``.
    public func scope<CaseState: ObservableState, CaseAction: Sendable>(
        state casePath: CaseKeyPath<ChildState, CaseState>,
        action embed: CaseKeyPath<ChildAction, CaseAction>,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> ScopedViewModel<CaseState, CaseAction> {
        guard let scoped = scopeIfActive(state: casePath, action: embed) else {
            fatalError(
                """
                scope(state:action:) at \(fileID):\(line): scoped into case '\(casePath)' \
                while it is not the active case of the child slice. Call this only inside a \
                switch case that matched the same case, or use scopeIfActive(state:action:).
                """
            )
        }
        return scoped
    }
}
```

No changes to the action loop, `ScopedViewModel`'s stored representation, or Spec B's existing
overloads. There is no ambiguity with Spec B's key-path `scope`: for an enum view state,
`\.success` cannot satisfy `KeyPath<ViewState, ChildState>` with `ChildState: ObservableState`
(the dynamic-member key path lands on an optional), so only the `CaseKeyPath` overload is
viable — and vice versa for struct view state.

### Observation trace (why this is fine-grained)

Reading `model.title` through a case scope registers: the coarse `\.viewState` (gated on root
`_$id` — fires only on a case change or wholesale payload rebuild, exactly when the child
should die or fully refresh) and `\.title` on the payload's own registrar (fires on in-place
mutation). The `switch` view registers only the coarse key path. So: in-place payload mutation
re-renders only the leaf child; case change re-renders the `switch`, which tears down the child
and builds the new case's subtree. For a nested enum slice (`scope(state: \.phase, action:
\.phase)` per Spec B, then case-scoping the result), the containing registrar's `\.phase` fires
on case changes via `didModify` identity comparison — same shape, one level down.

## Tests

New file `Tests/LatticeTests/PresentationTests/EnumCaseScopingTests.swift`:

```swift
import CasePaths
import Foundation
import Observation
import Testing

@testable import Lattice

private final class ChangeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hasChanged = false
    var didChange: Bool { lock.withLock { hasChanged } }
    func mark() { lock.withLock { hasChanged = true } }
}

@ObservableState private struct SuccessViewState: Equatable, Sendable {
    var title: String
    var count: Int
}

@CasePathable
@ObservableState private enum PhaseViewState: Equatable, Sendable, DefaultValueProvider {
    static let defaultValue = Self.loading
    case loading
    case success(SuccessViewState)
}

private struct PhaseDomain: Equatable, Sendable {
    var isLoaded = false
    var title = "t"
    var count = 0
    var tick = 0
}

@CasePathable private enum SuccessAction: Sendable {
    case titleChanged(String)
    case incremented
}

@CasePathable private enum PhaseAction: Sendable {
    case load
    case reset
    case tick
    case success(SuccessAction)
}

private struct PhaseInteractor: Interactor, Sendable {
    typealias DomainState = PhaseDomain
    typealias Action = PhaseAction
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .load: state.isLoaded = true
            case .reset: state.isLoaded = false
            case .tick: state.tick += 1
            case .success(let action):
                // Late sends after the case deactivated are dropped here, by design.
                guard state.isLoaded else { return .none }
                switch action {
                case .titleChanged(let t): state.title = t
                case .incremented: state.count += 1
                }
            }
            return .none
        }
    }
}

/// Fine-grained regime: transitions rebuild the case; steady-state updates mutate the payload
/// in place through the case.
private struct PhaseReducer: ViewStateReducer, Sendable {
    typealias DomainState = PhaseDomain
    typealias ViewState = PhaseViewState
    // PhaseViewState: DefaultValueProvider supplies the initial view state.
    var body: some ViewStateReducerOf<Self> {
        BuildViewState { s, v in
            guard s.isLoaded else {
                v = .loading
                return
            }
            if v.is(\.success) {
                v.modify(\.success) {          // in-place: payload registrar fires leaves only
                    $0.title = s.title
                    $0.count = s.count
                }
            } else {
                v = .success(SuccessViewState(title: s.title, count: s.count))  // case transition
            }
        }
    }
}

@MainActor
@Suite struct EnumCaseScopingTests {
    private func makeViewModel() -> ViewModel<Feature<PhaseAction, PhaseDomain, PhaseViewState>> {
        ViewModel(
            initialDomainState: PhaseDomain(),
            feature: Feature(interactor: PhaseInteractor(), reducer: PhaseReducer())
        )
    }

    // MARK: Prerequisite fix (_$inert)

    @Test func payloadlessCaseIsStable_unrelatedReduceDoesNotFireCoarse() {
        let vm = makeViewModel()   // .loading
        let probe = ChangeProbe()
        withObservationTracking { _ = vm.viewState } onChange: { probe.mark() }

        vm.sendViewEvent(.tick)    // domain changes; view state stays .loading
        #expect(!probe.didChange)  // fails before the _$inert fix
    }

    @Test func caseChangeStillFiresCoarse() {
        let vm = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = vm.viewState } onChange: { probe.mark() }

        vm.sendViewEvent(.load)    // .loading -> .success
        #expect(probe.didChange)
    }

    // MARK: Case scoping

    @Test func trappingScopeReadsLivePayload() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)
        #expect(success.title == "t")

        success.sendViewEvent(.titleChanged("new"))   // in-place reduce
        #expect(success.title == "new")               // live re-extraction, not a snapshot
    }

    @Test func scopeIfActiveReturnsNilForInactiveCase() {
        let vm = makeViewModel()   // .loading
        #expect(vm.scopeIfActive(state: \.success, action: \.success) == nil)
    }

    @Test func inPlacePayloadMutationIsFineGrained() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)

        let titleProbe = ChangeProbe()
        withObservationTracking { _ = success.title } onChange: { titleProbe.mark() }
        let coarseProbe = ChangeProbe()
        withObservationTracking { _ = vm.viewState } onChange: { coarseProbe.mark() }

        success.sendViewEvent(.incremented)   // in-place: only count changes
        #expect(!titleProbe.didChange)        // sibling leaf not invalidated
        #expect(!coarseProbe.didChange)       // switch not re-rendered
    }

    @Test func caseFlipServesCreationSnapshotWithoutCrashing() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)

        vm.sendViewEvent(.reset)     // .success -> .loading; scope is now stale
        #expect(success.title == "t")   // creation snapshot, no trap/crash
    }

    @Test func lateSendAfterCaseFlipIsDroppedByInteractor() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)
        vm.sendViewEvent(.reset)

        success.sendViewEvent(.incremented)   // arrives while .loading
        vm.sendViewEvent(.load)
        #expect(vm.viewState[case: \.success]?.count == 0)   // guard dropped it
    }

    @Test func bindingThroughCaseScope() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)
        let binding = success.binding(\.title, sending: \.titleChanged)
        #expect(binding.wrappedValue == "t")
        binding.wrappedValue = "typed"
        #expect(binding.wrappedValue == "typed")
    }
}
```

The trapping path itself is not unit-tested (no exit-test infrastructure in the suite); the
optional primitive's `nil` path covers the branch, and the trap is a `fatalError`
whose condition is pinned by `scopeIfActiveReturnsNilForInactiveCase`.

## Demo project

Extend the `ExampleProject/ScopedCompositionExamplePackage` created by Spec B's Demo project
section (see [`scoped-view-composition.md`](./scoped-view-composition.md)) with a second
screen — **not** a new package. Add the phase feature's files alongside the existing ones
(`Architecture/Phase*.swift`, a `PhaseExampleView.swift`, and a public
`PhaseExampleAppView.swift` entry that builds the `Feature` + `ViewModel` in `@State`, mirroring
`ScopedCompositionExampleAppView`), and wire a new `case enumCaseScoping` into the private
`Example` enum in `ExampleProject/ExampleProject/ContentView.swift` (title "Enum Case Scoping
Example", navigation title "Enum Case Scoping", `destinationView` `PhaseExampleAppView()`).
Use the example project's macro conventions (`@Interactor`, `@ViewStateReducer` with
`Self.buildViewState`) rather than this spec's protocol-spelled test fixtures.

The demo must make three things visible in a running app: the fine-grained in-place path
through a case scope, the coarse case-change path, and the `_$inert` fix.

Shape — the whole view state is the enum, same names as this spec's fixtures, with a `tick`
added to the success payload so the tick stream is visible on screen:

```swift
@CasePathable
@ObservableState
enum PhaseViewState: Equatable, Sendable {
    case loading
    case success(SuccessViewState)
}

@ObservableState
struct SuccessViewState: Equatable, Sendable {
    var title: String
    var count: Int
    var tick: Int
}
```

Domain state is flat (`isLoaded`/`title`/`count`/`tick`); the root event enum `PhaseEvent` has
`loadTapped`, `loaded`, `resetTapped`, `startTicking`, `tick`, and `success(SuccessAction)`
cases, with `SuccessAction` as in the fixtures (`titleChanged(String)`/`incremented`). The
interactor:

- `.loadTapped` fakes an async load: `return .perform { try? await clock.sleep(for: .seconds(1));
  return .loaded }` (the `.perform` convention used by `SearchExamplePackage`'s interactors);
  `.loaded` sets `isLoaded = true` and `.resetTapped` clears it.
- A once-per-second tick stream via `.observe` (the `TimerLeakExamplePackage` convention),
  started from a view event on appear, bumps `state.tick` — the unrelated-reduce driver for the
  `_$inert` behavior below.
- `.success(...)` actions are guarded on `isLoaded` and dropped otherwise (the late-send
  discipline from "Late sends").

The reducer keeps this spec's two-regimes discipline exactly as `PhaseReducer` does: `.loading`
when not loaded; when loaded, **in place** via `v.modify(\.success) { ... }` if already in the
case (title, count, and tick), wholesale `v = .success(SuccessViewState(...))` only on the
`.loading → .success` transition.

The root view is a plain exhaustive `switch` over `viewModel.viewState`, with load/reset
buttons outside the switch and a `ponytail:`-marked render counter (the same instrumentation as
Spec B's demo views) counting evaluations of the switch-owning body:

```swift
struct PhaseExampleView: View {
    let viewModel: PhaseExampleViewModel
    // ponytail: render counter is demo-only instrumentation, not a real pattern
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading) {
            switch viewModel.viewState {      // coarse read: re-renders on case change only
            case .loading:
                ProgressView("Loading…")
            case .success:
                SuccessView(model: viewModel.scope(state: \.success, action: \.success))
            }
            Button("Load") { viewModel.sendViewEvent(.loadTapped) }
            Button("Reset") { viewModel.sendViewEvent(.resetTapped) }
            Text("PhaseExampleView renders: \(renders.count)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await viewModel.sendViewEvent(.startTicking).finish() }
    }
}

struct SuccessView: View {
    let model: ScopedViewModel<SuccessViewState, SuccessAction>
    // ponytail: render counter is demo-only instrumentation, not a real pattern
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading) {
            TextField("Title", text: model.binding(\.title, sending: \.titleChanged))
            Button("Increment") { model.sendViewEvent(.incremented) }
            Text("Count: \(model.count)   Tick: \(model.tick)")
            Text("SuccessView renders: \(renders.count)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

Expected, demonstrable behavior:

- Typing in the **Title** field or tapping **Increment** (in-place payload mutations through
  `v.modify(\.success)`): only `SuccessView renders:` advances. The switch root registered only
  the coarse `\.viewState`, whose root `_$id` is untouched by in-place mutation, so
  `PhaseExampleView renders:` stays put.
- Tapping **Load** or **Reset** (case change): `PhaseExampleView renders:` advances — the root
  `_$id` changed, the coarse fire re-renders the switch, and the success subtree is built or
  torn down. This is the intended coarse channel, not a regression.
- While sitting in `.loading`, the tick stream keeps reducing unrelated domain state once per
  second, and `PhaseExampleView renders:` does **not** advance. This is the `_$inert` fix made
  visible: before it, `.loading._$id` minted a fresh UUID per access, the `_modify` gate saw a
  changed root `_$id` on every reduce, and the switch would re-render once per second while
  showing an unchanged spinner. (While in `.success`, the same ticks are in-place payload
  mutations: `Tick:` and `SuccessView renders:` advance each second, the switch still does not.)

This is the manual counterpart to `payloadlessCaseIsStable_*`, `inPlacePayloadMutationIsFineGrained`,
and `caseChangeStillFiresCoarse`.

## Validation

1. `scripts/rebuild-macro.sh` (enum expansion changed), then `swift build`.
2. `swift test --filter LatticeMacrosTests` — update payloadless-enum expansion snapshots.
3. `swift test --filter EnumCaseScopingTests`
4. `swift test --filter EnumRootObservationTests` and
   `swift test --filter FineGrainedObservationTests` — Spec A behavior unchanged (case changes
   still fire coarse).
5. `swift test --filter ScopedViewModelTests` — Spec B unchanged.
6. Demo: build the phase-enum screen specified in "Demo project" and confirm with the render
   counters plus `Self._printChanges()` that the expected behaviors listed there hold: typing
   and counting (in-place mutation) re-render only the success child, load/reset (case change)
   re-renders the `switch`, and ticks while in `.loading` re-render nothing (the `_$inert`
   fix).
7. `swift test` — full suite.

## Migration / API notes

- Purely additive. Existing switch-and-extract code keeps working under the wholesale-rebuild
  regime (coarse granularity); this spec adds the fine-grained path.
- Document the two-regimes rule prominently (this spec's Problem section is the source of
  truth): extraction pairs with wholesale rebuild; scope pairs with in-place mutation; mixing
  them shows stale data.
- Requires the view-state enum to be `@CasePathable` (user-applied; `@ObservableState` does not
  add it) and the payload to be `@ObservableState`.
- Payloadless cases need no scope: no state to project, and one-off actions are a plain
  `viewModel.sendViewEvent(...)` closure or Spec B's typed-callback handoff.
- Give enum payloads `@ObservableState` structure when their content changes matter for
  precision; a non-`ObservableState` payload (e.g. `.error(String)`) is observed coarsely by
  design (see the prerequisite-fix section).

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
