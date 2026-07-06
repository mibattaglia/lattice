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
    var title = "h"
    var badge = 0
    var footer = "f"
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
        BuildViewState<AppDomain, AppViewState> { s, v in
            v.header.title = s.title  // in-place
            v.header.badge.count = s.badge  // in-place
            v.footer = s.footer
        }
    }
}

/// Rebuilds the header slice wholesale on every reduce, for the coarse-read tests.
private struct WholesaleAppReducer: ViewStateReducer, Sendable {
    typealias DomainState = AppDomain
    typealias ViewState = AppViewState
    var body: some ViewStateReducerOf<Self> {
        BuildViewState<AppDomain, AppViewState> { s, v in
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

        vm.sendViewEvent(.setFooter("f2"))  // footer change
        #expect(!probe.didChange)  // header scope not invalidated
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
        let vm = makeViewModel()  // in-place reducer
        let header = vm.scope(state: \.header, action: \.header)
        let probe = ChangeProbe()
        withObservationTracking { _ = header.viewState } onChange: { probe.mark() }

        header.sendViewEvent(.titleChanged("new"))  // in-place leaf mutation
        #expect(!probe.didChange)  // container identity unchanged
        #expect(header.title == "new")  // reads still see the live value
    }

    @Test func wholeSliceReadInvalidatesOnWholesaleReplacement() {
        let vm = ViewModel(
            initialDomainState: AppDomain(),
            feature: Feature(interactor: AppInteractor(), reducer: WholesaleAppReducer())
        )
        let header = vm.scope(state: \.header, action: \.header)
        let probe = ChangeProbe()
        withObservationTracking { _ = header.viewState } onChange: { probe.mark() }

        header.sendViewEvent(.titleChanged("new"))  // reducer rebuilds header wholesale
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
        let header = vm.scope(state: \.header)  // ScopedViewModel<HeaderState, Never>
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

        erasedChildCallback("not a HeaderAction")  // consumer's cast drops it
        #expect(vm.viewState.header.title == "viaAny")
    }
}
