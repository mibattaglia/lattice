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

@ObservableState private struct Section: Equatable, Sendable {
    var title: String
    var subtitle: String
}

@ObservableState private struct DashViewState: Equatable, Sendable, DefaultValueProvider {
    static let defaultValue = Self(header: Section(title: "h", subtitle: "s"), count: 0)
    var header: Section
    var count: Int
}

private struct DashDomain: Equatable, Sendable { var count = 0; var title = "h"; var subtitle = "s" }

@CasePathable private enum DashAction: Sendable {
    case bumpCount        // changes only `count`
    case setTitle(String) // changes only `header.title` (in place)
}

private struct DashInteractor: Interactor, Sendable {
    typealias DomainState = DashDomain
    typealias Action = DashAction
    var body: some InteractorOf<Self> { self }
    func interact(state: inout DashDomain, action: DashAction) -> Emission<DashAction> {
        switch action {
        case .bumpCount: state.count += 1
        case .setTitle(let t): state.title = t
        }
        return .none
    }
}

private struct DashReducer: ViewStateReducer, Sendable {
    typealias DomainState = DashDomain
    typealias ViewState = DashViewState
    var body: some ViewStateReducerOf<Self> { self }
    func initialViewState(for s: DashDomain) -> DashViewState { .defaultValue }
    func reduce(_ s: DashDomain, into v: inout DashViewState) {
        v.count = s.count
        v.header.title = s.title          // in-place
        v.header.subtitle = s.subtitle    // in-place
    }
}

@MainActor
@Suite struct FineGrainedObservationTests {
    private func makeViewModel()
        -> ViewModel<Feature<DashAction, DashDomain, DashViewState>>
    {
        ViewModel(
            initialDomainState: DashDomain(),
            feature: Feature(interactor: DashInteractor(), reducer: DashReducer())
        )
    }

    @Test func unrelatedChangeDoesNotInvalidate() {
        let vm = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = vm.header.title } onChange: { probe.mark() }

        vm.sendViewEvent(.bumpCount)      // changes count, not header.title
        #expect(!probe.didChange)
    }

    @Test func relatedChangeInvalidates() {
        let vm = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = vm.header.title } onChange: { probe.mark() }

        vm.sendViewEvent(.setTitle("new"))
        #expect(probe.didChange)
        #expect(vm.viewState.header.title == "new")
    }

    @Test func inPlaceSiblingMutationIsFineGrained() {
        let vm = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = vm.header.subtitle } onChange: { probe.mark() }

        vm.sendViewEvent(.setTitle("new"))   // only title changes, in place
        #expect(!probe.didChange)
    }
}

// When the whole view state is the enum itself:
@ObservableState private enum RootPhaseViewState: Equatable, Sendable, DefaultValueProvider {
    static let defaultValue = Self.loading
    case loading
    case content(String)
}

private struct PhaseDomain: Equatable, Sendable { var loaded = false; var text = "" }

@CasePathable private enum PhaseAction: Sendable {
    case load(String)   // .loading -> .content (case change)
}

private struct PhaseInteractor: Interactor, Sendable {
    typealias DomainState = PhaseDomain
    typealias Action = PhaseAction
    var body: some InteractorOf<Self> { self }
    func interact(state: inout PhaseDomain, action: PhaseAction) -> Emission<PhaseAction> {
        switch action {
        case .load(let t): state.loaded = true; state.text = t
        }
        return .none
    }
}

private struct RootPhaseReducer: ViewStateReducer, Sendable {
    typealias DomainState = PhaseDomain
    typealias ViewState = RootPhaseViewState
    var body: some ViewStateReducerOf<Self> { self }
    func initialViewState(for s: PhaseDomain) -> RootPhaseViewState { .loading }
    func reduce(_ s: PhaseDomain, into v: inout RootPhaseViewState) {
        v = s.loaded ? .content(s.text) : .loading
    }
}

@MainActor
@Suite struct EnumRootObservationTests {
    private func makeViewModel()
        -> ViewModel<Feature<PhaseAction, PhaseDomain, RootPhaseViewState>>
    {
        ViewModel(
            initialDomainState: PhaseDomain(),
            feature: Feature(interactor: PhaseInteractor(), reducer: RootPhaseReducer())
        )
    }

    // A view that `switch`es over the enum registers only `\.viewState`; a case change must
    // re-render it. This is the regression that deleting the coarse fire would break.
    @Test func caseChangeInvalidatesWholeStateObserver() {
        let vm = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = vm.viewState } onChange: { probe.mark() }

        vm.sendViewEvent(.load("hi"))   // .loading -> .content : root _$id changes
        #expect(probe.didChange)
        #expect(vm.viewState == .content("hi"))
    }
}
