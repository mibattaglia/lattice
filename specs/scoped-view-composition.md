# Scoped View Composition (Spec B): `scope(state:action:)` child projection

Status: ✅ Implemented — depends on
[`observable-state-identity-preserving-merge.md`](./observable-state-identity-preserving-merge.md)
**and** [`fine-grained-observation.md`](./fine-grained-observation.md) (Spec A).

## Problem

Lattice had no TCA-style `store.scope(state:action:)` for composing subviews around a part of a
feature. A child view that should own "the header" had to either take the whole `ViewModel<F>`
(coupling it to the parent feature's full action/state surface) or receive detached value
snapshots (losing observation). The only composition was domain-side (`When` in the
interactor), not a view-facing projection.

Spec A made all state reads fine-grained: reading `viewModel.<member>` (the `dynamicMember`
subscript) registers on the state's nested `@FeatureState` registrars, and the coarse `\.state`
only fires when the root `_$id` changes. Spec B builds the composition handle on top: a child
projection that exposes a child state with fine-grained observation **and** maps child view
events into parent actions — with no detached snapshots and no identity churn.

## Key simplification vs TCA

TCA's scoping is heavy because child `Store`s are **reference types that own reducers,
effects, and lifetime**, forcing scope caching by identity to avoid recreating stateful stores
each render (a historic source of bugs).

Lattice's child is **stateless**: all state lives in the parent's stored state, all effects run
in the parent's action loop (`SendScopeID`/`RootScopeState`), and all observation goes through
the parent's registrar tree (Spec A). So the child projection is a **value type that is cheap
to recreate every render** — no caching, no lifecycle, no parent↔child retain cycle to manage.
This is the central design decision and the reason B is far smaller here than in TCA.

## Goal

```swift
struct DashboardView: View {
    @State var viewModel: ViewModel<DashboardFeature>
    var body: some View {
        HeaderView(model: viewModel.scope(state: \.header, action: \.header))
        FooterView(model: viewModel.scope(state: \.footer, action: \.footer))
    }
}

struct HeaderView: View {
    let model: ScopedViewModel<HeaderState, HeaderAction>
    var body: some View {
        Text(model.title)                          // fine-grained read on the header's registrar
        TextField("Title", text: model.binding(\.title, sending: \.titleChanged))
        Button("Refresh") { model.sendViewEvent(.refreshTapped) }   // embeds into parent action
    }
}
```

`HeaderView` re-renders only when a header member it reads changes, never when `footer` or
unrelated members change. `DashboardView` does not re-render when `header.title` changes (it
created the scope but read nothing observable).

## Design

`ScopedViewModel<Child: FeatureState, ChildAction>` is a `@MainActor` value type that erases the
parent feature `F` via two closures:

- `state: () -> Child` — reads the child **live** from the parent on every access:
  `State.ViewState(parent.state)[keyPath: keyPath]._state`. The key path is rooted at the
  parent's `ViewState` and lands on the child's projection `P: ViewStateProjection`; the raw
  child is recovered as `P.State` through the SPI `_state`, so `\.header` infers without
  annotation. Members read through the scope register on the child's own registrars, and the
  read through the parent registers the parent's root.
- `send: (ChildAction) -> EventTask` — embeds the child action into the parent action and calls
  `parent.sendViewEvent`, returning the parent's `EventTask`. The embedding is supplied either as
  a `CaseKeyPath` (sugar) or a plain `(ChildAction) -> Action` closure (general form, no
  `CasePathable` requirement). Both build the same closure.

Reads through the scope go through `Child.ViewState`: `model.title` is
`Child.ViewState(state())[keyPath: \.title]`, so a child's `@Domain` member is rejected at the
scope's read site exactly as on the view model. The state closure always reads live; a captured
child value would still be notified (it shares the live registrars) but would serve stale data.

Because `send` is just a closure, `sendViewEvent(_:)` is also the handoff for child views that
take a typed `(ChildAction) -> Void` callback: wrap it in a closure,
`{ scoped.sendViewEvent($0) }` (a bare method reference will not type-check — Swift 6 cannot
strip the `@MainActor` isolation). Children that declare a type-erased `(Any) -> Void` callback
(common in shared/legacy views) are bridged with a one-line cast at the call site, not a shipped
projection — see "Out of scope" for the rationale.

Erasing `F` keeps child views decoupled from the parent feature type. Closures capture the
parent `ViewModel` strongly; this is safe because the parent is owned by the parent view's
`@State`, and the scope struct (held transiently by the child view) never outlives it — there
is no cycle since the `ViewModel` does not retain the scope. The transience is the contract:
a scope stashed in long-lived storage (e.g. a child's `@State`) keeps the parent `ViewModel`
alive past its owning view, delaying the effect cancellation in its `deinit` — hence the
"create inline in `body`, don't store" guidance in the doc comment.

## API

The implementation is
[`ScopedViewModel.swift`](../Sources/Lattice/Presentation/ViewModel/ScopedViewModel.swift):

```swift
@MainActor @dynamicMemberLookup
public struct ScopedViewModel<Child: FeatureState, ChildAction: Sendable> {
    public var viewState: Child.ViewState                                         // coarse value
    public subscript<V>(dynamicMember keyPath: KeyPath<Child.ViewState, V>) -> V  // fine-grained
    @discardableResult public func sendViewEvent(_ action: ChildAction) -> EventTask
    public func binding<V>(
        _ keyPath: KeyPath<Child.ViewState, V>, sending embed: CaseKeyPath<ChildAction, V>
    ) -> Binding<V>
}

/// Lets `ForEach(viewModel.scope(state: \.rows, action: \.row))` identify rows.
extension ScopedViewModel: @MainActor Identifiable where Child: Identifiable {
    public var id: Child.ID { _state().id }
}
```

The scoping overloads exist identically on `ViewModel` (key paths rooted at `State.ViewState`)
and on `ScopedViewModel` (rooted at `Child.ViewState`, for grandchildren). Each primitive is
implemented once on `ScopedViewModel`; the `ViewModel` overloads delegate to a scope over the
whole state.

| Overload | Returns | Notes |
|---|---|---|
| `scope(state: KeyPath<_, P>, action: CaseKeyPath<_, ChildAction>)` | `ScopedViewModel<P.State, ChildAction>` | `P: ViewStateProjection`; requires a `@CasePathable` action |
| `scope(state: KeyPath<_, P?>, action: CaseKeyPath<_, ChildAction>)` | `ScopedViewModel<P.State, ChildAction>?` | `nil` while the child is absent; after removal, serves the creation snapshot for the at-most-one transitional render |
| `scope(state: KeyPath<_, ViewStateCollection<C>>, action: CaseKeyPath<_, (C.Element.ID, ChildAction)>)` | `[ScopedViewModel<C.Element, ChildAction>]` | elements are `FeatureState & Identifiable`; each scope re-finds its element by id on every read (O(n)) |
| `scope(state: KeyPath<_, ViewStateCollection<IdentifiedArray<ID, Element>>>, action: CaseKeyPath<_, (ID, ChildAction)>)` | `[ScopedViewModel<Element, ChildAction>]` | `IdentifiedArray` specialisation: O(1) lookup through `[id:]`; preferred by overload ranking |
| `scope(state: KeyPath<_, P>, action: @escaping @MainActor (ChildAction) -> Action)` | `ScopedViewModel<P.State, ChildAction>` | closure-mapped action; no `CasePathable` requirement |
| `scope(state: KeyPath<_, P>)` | `ScopedViewModel<P.State, Never>` | read-only child |

A collection scope serves the element captured at its creation if the element is removed while
the scope is still held. The enum-case overloads (`scopeIfActive(state:action:)` and the
trapping `scope(state:action:fileID:line:)`) are specified in
[`enum-case-scoping.md`](./enum-case-scoping.md) (Spec C).

The read-only scope's send closure is unreachable; it is typed `(Never) -> EventTask` and
returns `EventTask(rawValue: nil)`, the internal initializer `ViewModel` uses for a send without
effects.

No changes to the action loop or the macro were needed. Both the closure and case-path forms
compile down to the same `send` closure — no new runtime representation.

## Why no caching/lifecycle is needed

- **State**: derived on demand from the parent (`state()`), never stored. Recreating the
struct each render re-derives the same value.
- **Observation**: registration happens on the parent's stable registrar tree (Spec A +
merge invariant), so re-creating the scope does not detach observers.
- **Effects**: `sendViewEvent` runs in the parent's loop; the child starts/owns nothing.
- **Identity**: the child view's `body` reads (e.g. `model.title`) register on the parent's
registrar tree; whether `model` is a fresh struct each render is irrelevant.

Contrast TCA, where a scoped `Store` is a stateful reference that must be cached by scope
identity to preserve in-flight effects and avoid teardown churn. None of that applies here.

### Re-render cost when the parent re-renders (accepted trade-off)

Passing the parent `ViewModel` down directly lets SwiftUI skip the child when the parent's
body re-runs: `ViewModel` is a reference type, so the child's input is reference-equal across
renders. A `ScopedViewModel` holds closures, so SwiftUI's structural input-equality check can
never prove it unchanged — whenever the scope-creating parent re-renders, every scoped child
re-renders with it.

This is the accepted cost of the feature's purpose: decoupling child views from the parent
feature type. It is invisible in practice when the scope-creating parent reads little or no
observable state itself — the recommended shape, as in the Goal example, where `DashboardView`
reads nothing observable and therefore almost never re-renders. Keep scope creation in
read-light container views.

## Tests

`Tests/LatticeTests/PresentationTests/ScopedViewModelTests.swift` covers every overload on both
`ViewModel` and `ScopedViewModel`:

- Child: `scopedReadReflectsParentState`, `scopedSendEmbedsIntoParentAction`,
  `scopedSendReturnsParentEventTaskForEffects`, `scopedComputedMemberReadsDomainMember`,
  `scopedReadIsFineGrained_unrelatedSliceDoesNotInvalidate`,
  `scopedReadInvalidatesOnSliceChange`,
  `wholeSliceReadIsCoarse_inPlaceLeafMutationDoesNotInvalidate`,
  `wholeSliceReadInvalidatesOnWholesaleReplacement`, `nestedScopeComposes`,
  `readOnlyScopeHasNoActionSurface`, `bindingGetterIsFineGrainedAndSetterSends`,
  `closureActionOverloadEmbedsWithoutCasePaths`, `sendViewEventActsAsTypedCallbackHandoff`,
  `anyVoidChildBridgesAtCallSite`.
- Optional child: `optionalChildScopeIsNilWhileAbsentAndLiveWhilePresent`,
  `optionalChildScopeServesItsSnapshotAfterRemoval`.
- Collections: `arrayCollectionScopesReFindTheirElementByID`,
  `identifiedArrayCollectionScopesReFindTheirElementByID`,
  `collectionScopesAreIdentifiableForForEach`,
  `collectionScopeServesItsSnapshotAfterTheElementIsRemoved`.
- Overloads on `ScopedViewModel`: `scopedViewModelScopesIntoCollectionsOptionalsAndClosures`.

Excerpt:

```swift
@FeatureState private struct HeaderState: Equatable, Sendable {
    var title: String
    var badge: BadgeState
    @Domain var refreshCount = 0
    var refreshText: String { refreshCount == 0 ? "Never refreshed" : "Refreshed \(refreshCount)x" }
}

@FeatureState private struct RowState: Equatable, Identifiable, Sendable {
    let id: Int
    var title: String
    var count = 0
    // … mutating func apply(_ action: RowAction)
}

@FeatureState private struct ListState: Equatable, Sendable {
    var rows: [RowState] = [RowState(id: 1, title: "one"), RowState(id: 2, title: "two")]
    var idRows: IdentifiedArrayOf<RowState> = [RowState(id: 1, title: "one"), RowState(id: 2, title: "two")]
    var selection: RowState?
}

@CasePathable private enum ListAction: Sendable {
    case row(RowState.ID, RowAction)
    case idRow(RowState.ID, RowAction)
    case selection(RowAction)
    case select(RowState.ID?)
    case insertAtFront
    case remove(RowState.ID)
}

@MainActor
@Suite struct ScopedViewModelTests {
    // … makeViewModel(), makeListViewModel()

    @Test func wholeSliceReadIsCoarse_inPlaceLeafMutationDoesNotInvalidate() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let coarse = ObservationProbe { _ = header.viewState }

        header.sendViewEvent(.titleChanged("new"))  // in-place leaf mutation
        #expect(!coarse.didFire)  // the path to the header is unchanged
        #expect(header.title == "new")  // reads still see the live value
    }

    @Test func arrayCollectionScopesReFindTheirElementByID() {
        let vm = makeListViewModel()
        let rows = vm.scope(state: \.rows, action: \.row)
        #expect(rows.map(\.id) == [1, 2])

        rows[1].sendViewEvent(.incremented)
        #expect(rows[1].count == 1)
        #expect(vm.rows[1].count == 1)

        vm.sendViewEvent(.insertAtFront)  // shifts positions; each scope follows its id
        #expect(rows[1].id == 2)
        #expect(rows[1].count == 1)
        rows[1].sendViewEvent(.titleChanged("deux"))
        #expect(vm.rows[2].title == "deux")
    }
}
```

The negative compile checks (`scripts/negative-compile-checks.sh`, flags `LEAK_SCOPED` and
`LEAK_KEYPATH`) assert that a scoped read, a collection-scope read and a scoped binding reject a
`@Domain` member.

## Demo project

`ExampleProject/ScopedCompositionExamplePackage` (the `case scopedComposition` entry of
`ContentView.swift`'s `Example` enum) makes two things visible in a running app: the
fine-grained re-render boundary of each scoped child, and the read-light-container discipline
from "Re-render cost when the parent re-renders".

The feature's one state is composed of nested `@FeatureState` children, one level deeper than
the Goal example so chained scoping is exercised past one hop (`App > Dashboard > Header >
Badge`, plus a `Footer` sibling):

```swift
@FeatureState
struct ScopedCompositionState: Equatable, Sendable {
    var dashboard: DashboardState = DashboardState()
    var footer: FooterState = FooterState()
}

@FeatureState
struct DashboardState: Equatable, Sendable {
    var header: HeaderState = HeaderState()
}

@FeatureState
struct HeaderState: Equatable, Sendable {
    var title: String = "Dashboard"
    var badge: BadgeState = BadgeState()
}

@FeatureState
struct BadgeState: Equatable, Sendable {
    var label: String = "Badge"
    var count: Int = 0
}

@FeatureState
struct FooterState: Equatable, Sendable {
    var status: String = "Ready"
}
```

Child actions nest the same way (`BadgeAction` ⊂ `HeaderAction` ⊂ `DashboardAction` ⊂
`ScopedCompositionEvent`, all `@CasePathable`; the root event also has a `setFooter(String)`
case), and the interactor mutates every leaf **in place** (for example
`state.dashboard.header.badge.count += 1`) so leaf changes stay fine-grained (see Spec A's
precision model). The view tree is one thin view per level, each holding a `ScopedViewModel`
created inline in `body` by the chained `scope(state:action:)` calls:

```text
ScopedCompositionView                 owns the ViewModel; buttons only send — reads nothing observable
├─ DashboardView(model: viewModel.scope(state: \.dashboard, action: \.dashboard))
│   └─ HeaderView(model: model.scope(state: \.header, action: \.header))     reads model.title
│       └─ BadgeView(model: model.scope(state: \.badge, action: \.badge))    the leaf
└─ FooterView(model: viewModel.scope(state: \.footer))                       read-only scope
```

The root view hosts two buttons that drive non-leaf mutations: **Rename header** (sends
`.dashboard(.header(.titleChanged(...)))` with a random suffix) and **Update footer** (sends
`.setFooter(...)`). `BadgeView` is the leaf and carries the `binding(_:sending:)` text field
plus a counter button. `DashboardView` is the degenerate container case: it reads nothing
observable and only creates the header scope. `FooterView` reads `model.status` through the
read-only `ScopedViewModel<FooterState, Never>`.

Every view counts its `body` runs in one shared `RenderCounters` object (`root`, `dashboard`,
`header`, `badge`, `footer`), read through `@Environment(\.renderCounters)` (an `@Entry`
environment value) and injected by `ScopedCompositionExampleAppView` from its own `@State`. A
counter stored in the view value would start over every time SwiftUI re-creates the view, which
happens whenever the parent's `body` runs:

```swift
struct BadgeView: View {
    let model: ScopedViewModel<BadgeState, BadgeAction>
    @Environment(\.renderCounters) private var renderCounters

    var body: some View {
        renderCounters.badge += 1
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Label", text: model.binding(\.label, sending: \.labelChanged))
                .textFieldStyle(.roundedBorder)
            Button("Increment") { model.sendViewEvent(.incremented) }
                .buttonStyle(.bordered)
            Text("Count: \(model.count)")
            Text("BadgeView renders: \(renderCounters.badge)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

Expected, demonstrable behavior:

- Typing in the badge **Label** field or tapping **Increment** (leaf mutations): only
`BadgeView renders:` advances. `HeaderView` reads only `title`, so a badge-leaf change does
not invalidate it; `DashboardView`, the root, and `FooterView` stay put.
- Tapping **Rename header**: `HeaderView renders:` advances — and `BadgeView renders:` advances
with it, because `HeaderView` creates the badge scope and a `ScopedViewModel` input can never
be proven unchanged. This demonstrates the documented trade-off from "Re-render cost when the
parent re-renders" live; it is expected, not a bug. `DashboardView`, the root, and
`FooterView` stay put.
- Tapping **Update footer** (sibling-only mutation): only `FooterView renders:` advances — the
read-only `scope(state:)` projection is observation-live even though it can send nothing.
- `DashboardView renders:` and the root's counter never advance past 1: they create scopes but
read nothing observable. This is the read-light-container shape "Re-render cost when the
parent re-renders" recommends, validated rather than masked.

`ScopedCompositionExampleTests` checks the same boundaries with observation probes. Spec C
extends this package with a phase-enum screen — see the Demo project section of
[`enum-case-scoping.md`](./enum-case-scoping.md).

## Validation

1. `swift build`
2. `swift test --filter ScopedViewModelTests`
3. `swift test --filter FineGrainedObservationTests` (Spec A still green)
4. Demo app: confirm with the render counters plus `Self._printChanges()` / Instruments that
  - only the leaf child view re-renders on a leaf change,
  - parent/sibling views (`FooterView`) do **not** re-render on a child-only change, and
  - the scope-creating container views read nothing observable and therefore do not
  re-render on child changes — this validates the "read-light container" assumption from
  "Re-render cost when the parent re-renders" rather than masking it. (When a container
  *does* re-render, expect all its scoped children to re-render with it; that is the
  documented trade-off, not a bug.)
5. `swift test` — full suite, no regressions to existing `ViewModel`/binding tests.

## Migration / API notes

- `scope(state:action:)`, `scope(state:)`, and `ScopedViewModel` are public surface. Key paths
  are rooted at `State.ViewState` (or `Child.ViewState`) and land on a child's projection; the
  child type is recovered as `P.State`.
- The case-path action overloads require a `@CasePathable` action (the same constraint
  `_ViewModelBinding.sending` relies on). The closure overload and the read-only `scope(state:)`
  have no such constraint.
- Child states must be stored `@FeatureState` members reachable through `State.ViewState`: a
  child, an optional child, or a collection of `Identifiable` children. A computed member that
  builds a fresh child state on each read would hand the scope new registrars on every read,
  which defeats the registrar-identity invariant.
- Collection scopes need an action case that carries the element id, `(ID, ChildAction)`.
  Prefer `IdentifiedArrayOf` for O(1) lookup.
- The `Identifiable` conformance of `ScopedViewModel` is an isolated conformance
  (`@MainActor Identifiable`, SE-0470), which needs a Swift 6.2 compiler.
- `@dynamicMemberLookup` is shadowed by `ScopedViewModel`'s own API surface: a child member
  named `viewState`, `binding`, `scope`, `scopeIfActive`, or `sendViewEvent` resolves to the
  scope's member, not the child's. This mirrors the `ViewModel.viewState` behavior; avoid those
  names in state, or read through `viewState` explicitly.

## Out of scope

- `@Bindable`/`AllCasePaths` ergonomic parity with `_ViewModelBinding` /
`_ViewModelCaseBinding` for scoped models (case-path dynamic-member bindings). The
`binding(_:sending:)` helper covers the common case.
- Independent child interactors/effects. By design, scoped children have none — use a separate
`ViewModel` + interactor `When` composition for genuinely independent sub-features.
- A shipped `(Any) -> Void` projection on `ScopedViewModel`. At a `scope` call site both
`Action` and `ChildAction` are statically known, so erasing them discards checkable wiring,
and a built-in helper would have to pick a mismatch policy (silently drop vs. assert/crash)
on every consumer's behalf — turning a compile-time/loud error into a "button does nothing"
bug. Children declared with `(Any) -> Void` are the consumer's own boundary; bridge them with
the one-line cast shown on `sendViewEvent(_:)`, where the consumer owns the policy.
- Constructing a `ScopedViewModel` **from** an existing `(Any) -> Void` sink. It is lossy in ways the type would hide: there is no parent action loop to run in,
so `sendViewEvent` could only return `EventTask(rawValue: nil)` (every `await` becomes a
vacuous no-op, a correctness trap for tests), and the `state` getter would not be guaranteed
to register on the parent's nested registrar (defeats Spec A's fine-grained observation). If a
real call site appears where the root genuinely is not a `ViewModel` (e.g. a UIKit/legacy
controller exposing only `(Any) -> Void`), add it then as an explicitly named adapter
(`ScopedViewModel.erased(state:onEvent:)`) whose docs state it has no `EventTask` and no
observation guarantee — not as an overload of `scope` that would quietly contaminate the safe
path.
