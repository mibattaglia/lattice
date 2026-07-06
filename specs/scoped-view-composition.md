# Scoped View Composition (Spec B): `scope(state:action:)` child projection

Status: 🔧 Proposed — depends on
`[observable-state-identity-preserving-merge.md](./observable-state-identity-preserving-merge.md)`
**and** `[fine-grained-observation.md](./fine-grained-observation.md)` (Spec A) landing first.

## Problem

Lattice has no TCA-style `store.scope(state:action:)` for composing subviews around a slice of
a feature. A child view that should own "the header" must today either take the whole
`ViewModel<F>` (coupling it to the parent feature's full action/state surface and re-rendering
coarsely) or receive detached value snapshots (losing observation). The only existing
composition is domain-side (`When` in the interactor), not a view-facing projection.

Spec A made all view-state reads fine-grained: reading `viewModel.<member>` (the
`dynamicMember` subscript) registers on the view state's nested `@ObservableState` registrars,
and the coarse `\.viewState` only fires when the root `_$id` changes. Spec B builds the
composition handle on top: a child projection that
exposes a slice of view state with fine-grained observation **and** maps child view events into
parent actions — with no detached snapshots and no identity churn.

## Key simplification vs TCA

TCA's scoping is heavy because child `Store`s are **reference types that own reducers,
effects, and lifetime**, forcing scope caching by identity to avoid recreating stateful stores
each render (a historic source of bugs).

Lattice's child is **stateless**: all state lives in the parent's `_viewState`, all effects run
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
        Text(model.title)                          // fine-grained read on parent's header registrar
        TextField("Title", text: model.binding(\.title, sending: \.titleChanged))
        Button("Refresh") { model.sendViewEvent(.refreshTapped) }   // embeds into parent action
    }
}
```

`HeaderView` re-renders only when `header` changes, never when `footer` or unrelated slices
change. `DashboardView` does not re-render when `header.title` changes (it created the scope
but read nothing observable).

## Design

`ScopedViewModel<ChildState, ChildAction>` is a `@MainActor` value type that erases the parent
feature `F` via two closures:

- `state: () -> ChildState` — reads the slice through the parent's `dynamicMember` subscript
(`viewState[keyPath:]`), so it registers on the slice's nested `@ObservableState` registrar;
the coarse `\.viewState` only fires on root `_$id` change (Spec A).
- `send: (ChildAction) -> EventTask` — embeds the child action into the parent action and
calls `parent.sendViewEvent`, returning the parent's `EventTask`. The embedding is supplied
either as a `CaseKeyPath` (sugar) or a plain `(ChildAction) -> Action` closure (general
form, no `CasePathable` requirement). Both build the same closure.

Because `_send` is just a closure, `sendViewEvent(_:)` is also the handoff for child views
that take a typed `(ChildAction) -> Void` callback: wrap it in a closure,
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

## Source changes



### New file: `Sources/Lattice/Presentation/ViewModel/ScopedViewModel.swift`

```swift
import SwiftUI

#if canImport(CasePaths)
    import CasePaths
#endif

/// A stateless, fine-grained projection of a parent ``ViewModel`` onto a child slice of view
/// state and a child action space.
///
/// Create a scope with ``ViewModel/scope(state:action:)``. Reads register on the parent's
/// nested observation registrar, so a child view re-renders only when its own slice changes;
/// ``sendViewEvent(_:)`` embeds child actions into the parent action and runs them on the
/// parent's action loop.
///
/// ## Observe members, not the container
///
/// Read **members** through the scope (`model.title`, `model.badge.count`, or
/// ``binding(_:sending:)``) so observation tracks the live getter chain and the view re-renders
/// on in-place mutations. Reading the whole-slice ``viewState`` value registers only the
/// container's identity and will **not** re-render on an in-place leaf mutation — exactly the
/// same distinction as `viewModel.title` (fine-grained) versus `viewModel.viewState` (coarse).
/// Member access at any depth stays fine-grained because each hop invokes a live
/// `@ObservableState` getter; the rule is the chain of getters you actually read, not how deep
/// the slice is. (`@ObservableState` shares its observation registrar across value copies, so
/// reading members off a stored copy still tracks the live state — only reading the *whole*
/// container value is coarse.)
///
/// `ScopedViewModel` is a value type that owns no state, effects, or lifecycle, so it is cheap
/// to recreate on every render.
///
/// Create scopes inline in `body` and do not store them (e.g. in `@State` or any long-lived
/// property): a scope strongly retains its parent ``ViewModel``, so storing one beyond the
/// render that created it extends the parent's lifetime and delays the effect cancellation
/// that runs in the parent's `deinit`.
@dynamicMemberLookup
@MainActor
public struct ScopedViewModel<ChildState: ObservableState, ChildAction: Sendable> {
    private let _state: @MainActor () -> ChildState
    private let _send: @MainActor (ChildAction) -> EventTask

    init(
        state: @escaping @MainActor () -> ChildState,
        send: @escaping @MainActor (ChildAction) -> EventTask
    ) {
        self._state = state
        self._send = send
    }

    /// The current value of the whole child slice.
    ///
    /// This is the **coarse** read: it registers only the slice's identity (`_$id`), so like
    /// ``ViewModel/viewState`` it re-renders only on a wholesale slice replacement and **not**
    /// on an in-place leaf mutation. To observe leaf changes fine-grained, read members through
    /// the scope instead (`model.title`), which is the common case.
    public var viewState: ChildState { _state() }

    /// Accesses a member of the child slice with fine-grained observation.
    ///
    /// This is the **fine-grained** read: `model.title` (or deeper, `model.badge.count`) walks
    /// the live `@ObservableState` getter chain and re-renders the view on in-place mutations
    /// of that member. Prefer this over ``viewState`` in views.
    public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, Value>) -> Value {
        _state()[keyPath: keyPath]
    }

    /// Sends a child action, embedding it into the parent action and running it on the parent's
    /// action loop.
    ///
    /// To hand off to a child view that takes a `(ChildAction) -> Void` callback, wrap in a
    /// closure (the returned ``EventTask`` is discarded):
    ///
    /// ```swift
    /// ChildView(action: { scoped.sendViewEvent($0) })
    /// ```
    ///
    /// For a child declared with a type-erased `(Any) -> Void` callback, bridge at the call
    /// site, where the consumer who chose erasure owns the cast and its mismatch policy:
    ///
    /// ```swift
    /// ErasedChildView(action: { if let a = $0 as? ChildAction { scoped.sendViewEvent(a) } })
    /// ```
    ///
    /// - Parameter action: The child action to embed and dispatch.
    /// - Returns: The parent's ``EventTask`` for the dispatched action.
    @discardableResult
    public func sendViewEvent(_ action: ChildAction) -> EventTask {
        _send(action)
    }

    #if canImport(CasePaths)
        /// Returns a binding whose getter reads the given key path with fine-grained
        /// observation and whose setter sends the new value embedded as a child action.
        ///
        /// - Parameters:
        ///   - keyPath: A key path into the child slice to read.
        ///   - embed: A case key path that wraps the new value into a child action.
        /// - Returns: A two-way binding over the child slice.
        public func binding<Value>(
            _ keyPath: KeyPath<ChildState, Value>,
            sending embed: CaseKeyPath<ChildAction, Value>
        ) -> Binding<Value> {
            let state = self._state
            let send = self._send
            return Binding(
                get: { state()[keyPath: keyPath] },
                set: { newValue in _ = send(embed(newValue)) }
            )
        }
    #endif
}

#if canImport(CasePaths)
    extension ViewModel where Action: CasePathable {
        /// Projects this view model onto a child slice of view state and a child action space.
        ///
        /// The child action is embedded into this feature's action with `actionCasePath`. This
        /// is sugar over the closure-based ``scope(state:action:)`` overload.
        ///
        /// - Parameters:
        ///   - stateKeyPath: A key path to a nested `@ObservableState` slice of the view state.
        ///   - actionCasePath: A case key path that embeds the child action into this feature's
        ///     action.
        /// - Returns: A ``ScopedViewModel`` over the child slice and action.
        public func scope<ChildState: ObservableState, ChildAction: Sendable>(
            state stateKeyPath: KeyPath<ViewState, ChildState>,
            action actionCasePath: CaseKeyPath<Action, ChildAction>
        ) -> ScopedViewModel<ChildState, ChildAction> {
            // A CaseKeyPath is callable as (ChildAction) -> Action, so forward to the closure
            // overload below. The case-path form is just ergonomic sugar.
            scope(state: stateKeyPath, action: { actionCasePath($0) })
        }
    }

    extension ScopedViewModel {
        /// Projects this scope onto a grandchild slice and action space, composing through the
        /// parent.
        ///
        /// - Parameters:
        ///   - stateKeyPath: A key path from the child slice to a nested `@ObservableState`
        ///     grandchild slice.
        ///   - embed: A case key path that embeds the grandchild action into the child action.
        /// - Returns: A ``ScopedViewModel`` over the grandchild slice and action.
        public func scope<GrandState: ObservableState, GrandAction: Sendable>(
            state stateKeyPath: KeyPath<ChildState, GrandState>,
            action embed: CaseKeyPath<ChildAction, GrandAction>
        ) -> ScopedViewModel<GrandState, GrandAction> {
            let state = self._state
            let send = self._send
            return ScopedViewModel<GrandState, GrandAction>(
                state: { state()[keyPath: stateKeyPath] },
                send: { grandAction in send(embed(grandAction)) }
            )
        }
    }
#endif

extension ViewModel {
    /// Projects this view model onto a child slice of view state and a child action space,
    /// mapping child actions into parent actions with a closure.
    ///
    /// This is the general form and has no `CasePathable` requirement; the case-path
    /// ``scope(state:action:)`` overload is sugar over it. Reach for it when the parent action
    /// is not `@CasePathable`, or when the mapping is not a plain case embedding.
    ///
    /// - Parameters:
    ///   - stateKeyPath: A key path to a nested `@ObservableState` slice of the view state.
    ///   - embed: A closure that maps a child action into this feature's action.
    /// - Returns: A ``ScopedViewModel`` over the child slice and action.
    public func scope<ChildState: ObservableState, ChildAction: Sendable>(
        state stateKeyPath: KeyPath<ViewState, ChildState>,
        action embed: @escaping @MainActor (ChildAction) -> Action
    ) -> ScopedViewModel<ChildState, ChildAction> {
        ScopedViewModel(
            state: { [self] in self[dynamicMember: stateKeyPath] },   // fine-grained (Spec A)
            send: { [self] childAction in self.sendViewEvent(embed(childAction)) }
        )
    }

    /// Projects this view model onto a read-only child slice, for child views that display
    /// state but send no actions.
    ///
    /// - Parameter stateKeyPath: A key path to a nested `@ObservableState` slice of the view
    ///   state.
    /// - Returns: A ``ScopedViewModel`` whose action type is `Never`.
    public func scope<ChildState: ObservableState>(
        state stateKeyPath: KeyPath<ViewState, ChildState>
    ) -> ScopedViewModel<ChildState, Never> {
        ScopedViewModel(
            state: { [self] in self[dynamicMember: stateKeyPath] },
            send: { (_: Never) in EventTask(rawValue: nil) }
        )
    }
}
```

> `EventTask(rawValue:)` is the existing internal initializer used by `ViewModel.makeEventTask`
> for the empty/quiescent case (see `makeEventTask` in `ViewModel.swift`). The `Never` send
> closure is unreachable.



No changes to the action loop, the macro, or existing public APIs. `scope` is additive and
reuses the parent's `dynamicMember` subscript for fine-grained reads (Spec A) and the existing
`sendViewEvent` for writes. Both the closure and case-path forms compile down to the same
`_send` closure — no new runtime representation.

## Why no caching/lifecycle is needed

- **State**: derived on demand from the parent (`_state()`), never stored. Recreating the
struct each render re-derives the same value.
- **Observation**: registration happens on the parent's stable registrar tree (Spec A +
merge invariant), so re-creating the scope does not detach observers.
- **Effects**: `sendViewEvent` runs in the parent's loop; the child starts/owns nothing.
- **Identity**: the child view's `body` reads (e.g. `model.title`) register on the parent
registrar; whether `model` is a fresh struct each render is irrelevant.

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

New file `Tests/LatticeTests/PresentationTests/ScopedViewModelTests.swift`:

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

@ObservableState private struct BadgeState: Equatable, Sendable {
    var count: Int
}

@ObservableState private struct HeaderState: Equatable, Sendable {
    var title: String
    var badge: BadgeState
}

@ObservableState private struct AppViewState: Equatable, Sendable, DefaultValueProvider {
    static let defaultValue = Self(
        header: HeaderState(title: "h", badge: BadgeState(count: 0)),
        footer: "f"
    )
    var header: HeaderState
    var footer: String
}

private struct AppDomain: Equatable, Sendable {
    var title = "h"; var badge = 0; var footer = "f"
}

@CasePathable private enum BadgeAction: Sendable {
    case incremented
}

@CasePathable private enum HeaderAction: Sendable {
    case titleChanged(String)
    case badge(BadgeAction)
    case refreshTapped
}

@CasePathable private enum AppAction: Sendable {
    case header(HeaderAction)
    case setFooter(String)
}

private struct AppInteractor: Interactor, Sendable {
    typealias DomainState = AppDomain
    typealias Action = AppAction
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .header(.titleChanged(let t)): state.title = t
            case .header(.badge(.incremented)): state.badge += 1
            case .header(.refreshTapped):
                // Async effect: exercises EventTask propagation through the scope.
                return .perform { .header(.badge(.incremented)) }
            case .setFooter(let f): state.footer = f
            }
            return .none
        }
    }
}

private struct AppReducer: ViewStateReducer, Sendable {
    typealias DomainState = AppDomain
    typealias ViewState = AppViewState
    // AppViewState: DefaultValueProvider supplies the initial view state.
    var body: some ViewStateReducerOf<Self> {
        BuildViewState { s, v in
            v.header.title = s.title          // in-place
            v.header.badge.count = s.badge    // in-place
            v.footer = s.footer
        }
    }
}

/// Rebuilds the header slice wholesale on every reduce, for the coarse-read tests.
private struct WholesaleAppReducer: ViewStateReducer, Sendable {
    typealias DomainState = AppDomain
    typealias ViewState = AppViewState
    var body: some ViewStateReducerOf<Self> {
        BuildViewState { s, v in
            v.header = HeaderState(title: s.title, badge: BadgeState(count: s.badge))  // wholesale
            v.footer = s.footer
        }
    }
}

@MainActor
@Suite struct ScopedViewModelTests {
    private func makeViewModel() -> ViewModel<Feature<AppAction, AppDomain, AppViewState>> {
        ViewModel(
            initialDomainState: AppDomain(),
            feature: Feature(interactor: AppInteractor(), reducer: AppReducer())
        )
    }

    @Test func scopedReadReflectsParentState() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        #expect(header.title == "h")
        #expect(header.badge.count == 0)
    }

    @Test func scopedSendEmbedsIntoParentAction() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        header.sendViewEvent(.titleChanged("new"))
        #expect(vm.viewState.header.title == "new")
    }

    @Test func scopedSendReturnsParentEventTaskForEffects() async {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        // .refreshTapped spawns a .perform effect in the parent's loop; the returned EventTask
        // is the parent's root-scope handle, so finish() awaits the emitted follow-up action.
        await header.sendViewEvent(.refreshTapped).finish()
        #expect(vm.viewState.header.badge.count == 1)
    }

    @Test func scopedReadIsFineGrained_unrelatedSliceDoesNotInvalidate() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let probe = ChangeProbe()
        withObservationTracking { _ = header.title } onChange: { probe.mark() }

        vm.sendViewEvent(.setFooter("f2"))   // footer change
        #expect(!probe.didChange)            // header scope not invalidated
    }

    @Test func scopedReadInvalidatesOnSliceChange() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let probe = ChangeProbe()
        withObservationTracking { _ = header.title } onChange: { probe.mark() }

        header.sendViewEvent(.titleChanged("new"))
        #expect(probe.didChange)
    }

    @Test func wholeSliceReadIsCoarse_inPlaceLeafMutationDoesNotInvalidate() {
        let vm = makeViewModel()   // in-place reducer
        let header = vm.scope(state: \.header, action: \.header)
        let probe = ChangeProbe()
        withObservationTracking { _ = header.viewState } onChange: { probe.mark() }

        header.sendViewEvent(.titleChanged("new"))   // in-place leaf mutation
        #expect(!probe.didChange)                    // container identity unchanged
        #expect(header.title == "new")               // reads still see the live value
    }

    @Test func wholeSliceReadInvalidatesOnWholesaleReplacement() {
        let vm = ViewModel(
            initialDomainState: AppDomain(),
            feature: Feature(interactor: AppInteractor(), reducer: WholesaleAppReducer())
        )
        let header = vm.scope(state: \.header, action: \.header)
        let probe = ChangeProbe()
        withObservationTracking { _ = header.viewState } onChange: { probe.mark() }

        header.sendViewEvent(.titleChanged("new"))   // reducer rebuilds header wholesale
        #expect(probe.didChange)
    }

    @Test func nestedScopeComposes() {
        let vm = makeViewModel()
        // App > header > badge: chained scope onto a nested @ObservableState slice.
        let badge = vm.scope(state: \.header, action: \.header)
            .scope(state: \.badge, action: \.badge)
        #expect(badge.count == 0)
        badge.sendViewEvent(.incremented)
        #expect(vm.viewState.header.badge.count == 1)
    }

    @Test func readOnlyScopeHasNoActionSurface() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header)   // ScopedViewModel<HeaderState, Never>
        #expect(header.badge.count == 0)
    }

    @Test func bindingGetterIsFineGrainedAndSetterSends() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let binding = header.binding(\.title, sending: \.titleChanged)
        #expect(binding.wrappedValue == "h")
        binding.wrappedValue = "typed"
        #expect(vm.viewState.header.title == "typed")
    }

    @Test func closureActionOverloadEmbedsWithoutCasePaths() {
        let vm = makeViewModel()
        // General form: map child action -> parent action with a closure.
        let header = vm.scope(state: \.header, action: { AppAction.header($0) })
        header.sendViewEvent(.titleChanged("closure"))
        #expect(vm.viewState.header.title == "closure")
    }

    @Test func sendViewEventActsAsTypedCallbackHandoff() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        // Wrap in a closure to hand off to a child view's (HeaderAction) -> Void callback.
        let handler: @MainActor (HeaderAction) -> Void = { header.sendViewEvent($0) }
        handler(.titleChanged("viaSend"))
        #expect(vm.viewState.header.title == "viaSend")
    }

    @Test func anyVoidChildBridgesAtCallSite() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        // The consumer who chose (Any) -> Void owns the cast at the call site.
        let erasedChildCallback: (Any) -> Void = {
            if let a = $0 as? HeaderAction { header.sendViewEvent(a) }
        }

        erasedChildCallback(HeaderAction.titleChanged("viaAny"))
        #expect(vm.viewState.header.title == "viaAny")

        erasedChildCallback("not a HeaderAction")   // consumer's cast drops it
        #expect(vm.viewState.header.title == "viaAny")
    }
}
```



## Demo project

Add a new local example package `ExampleProject/ScopedCompositionExamplePackage` (an empty
placeholder directory already exists), mirroring the existing
`ExampleProject/FineGrainedExamplePackage` layout: a `Package.swift` with the same manifest
shape (swift-tools-version 6.2, platforms `.iOS(.v26)`/`.macOS(.v14)`, a `.package(path: "../..")`
dependency on Lattice, a `ScopedCompositionExample` library product, and a matching test
target), and sources split into `ScopedCompositionExampleAppView.swift` (the public entry that
builds the `Feature` + `ViewModel` in `@State`), the screen view file, and an `Architecture/`
folder with the domain state / event / interactor / view state / view-state reducer files.
Use the example project's macro conventions — `@Interactor`, `@ViewStateReducer` with
`Self.buildViewState`, a root event enum named `ScopedCompositionEvent` — rather than the
protocol spelling used in this spec's test fixtures.

Wire the package in everywhere `FineGrainedExamplePackage` is wired: a `FileRef` in
`ExampleProject/ExampleProjectWorkspace.xcworkspace/contents.xcworkspacedata`, a local package
reference + `ScopedCompositionExample` product dependency in
`ExampleProject/ExampleProject.xcodeproj`, and a new `case scopedComposition` in the private
`Example` enum in `ExampleProject/ExampleProject/ContentView.swift` (title "Scoped Composition
Example", navigation title "Scoped Composition", `destinationView`
`ScopedCompositionExampleAppView()`).

The demo must make two things visible in a running app: the fine-grained re-render boundary of
each scoped child, and the read-light-container discipline from "Re-render cost when the parent
re-renders".

Shape — one level deeper than the Goal example so chained scoping is exercised past one hop
(`App > Dashboard > Header > Badge`, plus a `Footer` sibling), with the same slice names as
this spec's fixtures:

```swift
@ObservableState struct ScopedCompositionViewState: Equatable, Sendable {
    var dashboard: DashboardState
    var footer: FooterState
}
@ObservableState struct DashboardState: Equatable, Sendable { var header: HeaderState }
@ObservableState struct HeaderState: Equatable, Sendable {
    var title: String
    var badge: BadgeState
}
@ObservableState struct BadgeState: Equatable, Sendable { var label: String; var count: Int }
@ObservableState struct FooterState: Equatable, Sendable { var status: String }
```

Child actions nest the same way (`BadgeAction` ⊂ `HeaderAction` ⊂ `DashboardAction` ⊂
`ScopedCompositionEvent`, all `@CasePathable`; the root event also has a `setFooter(String)`
case), the domain state is flat (`title`/`badgeLabel`/`badgeCount`/`footerStatus`), and the
reducer mutates **every slice in place** so leaf changes stay fine-grained (see Spec A's
precision model). The view tree is one thin view per level, each holding a `ScopedViewModel`
created inline in `body` by the chained `scope(state:action:)` calls:

```text
ScopedCompositionView                 owns the ViewModel; buttons only send — reads nothing observable
├─ DashboardView(model: viewModel.scope(state: \.dashboard, action: \.dashboard))
│   └─ HeaderView(model: model.scope(state: \.header, action: \.header))     reads model.title
│       └─ BadgeView(model: model.scope(state: \.badge, action: \.badge))    the leaf
└─ FooterView(model: viewModel.scope(state: \.footer))                       read-only scope
```

The root view hosts two buttons that drive non-leaf mutations, mirroring the fine-grained
demo's button row: **Rename header** (sends `.dashboard(.header(.titleChanged(...)))` with a
random suffix) and **Update footer** (sends `.setFooter(...)`). `BadgeView` is the leaf and
carries the `binding(_:sending:)` text field plus a counter button. Every view holds a
render counter (same instrumentation as `FineGrainedExamplePackage`'s
`HeaderView`) so re-render boundaries are visible:

```swift
struct BadgeView: View {
    let model: ScopedViewModel<BadgeState, BadgeAction>
    private final class Renders { var count = 0 }
    private let renders = Renders()

    var body: some View {
        renders.count += 1
        return VStack(alignment: .leading) {
            TextField("Label", text: model.binding(\.label, sending: \.labelChanged))
            Button("Increment") { model.sendViewEvent(.incremented) }
            Text("Count: \(model.count)")
            Text("BadgeView renders: \(renders.count)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

`DashboardView` is the degenerate container case: it reads nothing observable, creates the
header scope, and shows only its own render counter. `FooterView` reads `model.status` through
the read-only `ScopedViewModel<FooterState, Never>`.

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

Spec C extends this same package with a phase-enum screen — see the Demo project section of
`[enum-case-scoping.md](./enum-case-scoping.md)`.

## Validation

1. `swift build`
2. `swift test --filter ScopedViewModelTests`
3. `swift test --filter FineGrainedObservationTests` (Spec A still green)
4. Demo app: build the `ScopedCompositionExamplePackage` demo specified in "Demo project" and
  confirm with the render counters plus `Self._printChanges()` / Instruments that the expected
   behaviors listed there hold:
  - only the leaf child view re-renders on a leaf change,
  - parent/sibling views (`FooterView`) do **not** re-render on a child-only change, and
  - the scope-creating container views read nothing observable and therefore do not
  re-render on child changes — this validates the "read-light container" assumption from
  "Re-render cost when the parent re-renders" rather than masking it. (When a container
  *does* re-render, expect all its scoped children to re-render with it; that is the
  documented trade-off, not a bug.)
   This is the manual counterpart to `scopedReadIsFineGrained_*` and `nestedScopeComposes`,
   verifying granularity and action embedding survive real SwiftUI rendering at depth.
5. `swift test` — full suite, no regressions to existing `ViewModel`/binding tests.



## Migration / API notes

- Purely additive: `scope(state:action:)`, `scope(state:)`, and `ScopedViewModel` are new
public surface. Existing `ViewModel<F>` usage is unchanged.
- Requires `Action: CasePathable` for the action-embedding overload (the same constraint the
existing `_ViewModelBinding.sending` already relies on). The read-only `scope(state:)`
overload has no such constraint.
- Child state slices must be nested `@ObservableState` values reachable by key path (not
recomputed projections), which is what preserves the registrar-identity invariant and avoids
detached snapshots.
- `@dynamicMemberLookup` is shadowed by `ScopedViewModel`'s own API surface: a child slice
property named `viewState`, `binding`, `scope`, or `sendViewEvent` resolves to the scope's
member, not the slice's. This mirrors the pre-existing `ViewModel.viewState` behavior; avoid
those names in view state, or read through `viewState` explicitly.



## Out of scope

- `@Bindable`/`AllCasePaths` ergonomic parity with `_ViewModelBinding` /
`_ViewModelCaseBinding` for scoped models (case-path dynamic-member bindings). Add once the
core `scope` API proves out; the `binding(_:sending:)` helper covers the common case.
- Enum-case scoping (projecting a `ScopedViewModel` from an enum case's payload) — specced
separately in `[enum-case-scoping.md](./enum-case-scoping.md)` (Spec C), which depends on
this spec landing first.
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

