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
        BuildViewState<PhaseDomain, PhaseViewState> { s, v in
            guard s.isLoaded else {
                v = .loading
                return
            }
            if v.is(\.success) {
                v.modify(\.success) {  // in-place: payload registrar fires leaves only
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
        let vm = makeViewModel()  // .loading
        let probe = ChangeProbe()
        withObservationTracking { _ = vm.viewState } onChange: { probe.mark() }

        vm.sendViewEvent(.tick)  // domain changes; view state stays .loading
        #expect(!probe.didChange)  // fails before the _$inert fix
    }

    @Test func caseChangeStillFiresCoarse() {
        let vm = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = vm.viewState } onChange: { probe.mark() }

        vm.sendViewEvent(.load)  // .loading -> .success
        #expect(probe.didChange)
    }

    // MARK: Case scoping

    @Test func trappingScopeReadsLivePayload() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)
        #expect(success.title == "t")

        success.sendViewEvent(.titleChanged("new"))  // in-place reduce
        #expect(success.title == "new")  // live re-extraction, not a snapshot
    }

    @Test func scopeIfActiveReturnsNilForInactiveCase() {
        let vm = makeViewModel()  // .loading
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

        success.sendViewEvent(.incremented)  // in-place: only count changes
        #expect(!titleProbe.didChange)  // sibling leaf not invalidated
        #expect(!coarseProbe.didChange)  // switch not re-rendered
    }

    @Test func caseFlipServesCreationSnapshotWithoutCrashing() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)

        vm.sendViewEvent(.reset)  // .success -> .loading; scope is now stale
        #expect(success.title == "t")  // creation snapshot, no trap/crash
    }

    @Test func lateSendAfterCaseFlipIsDroppedByInteractor() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)
        vm.sendViewEvent(.reset)

        success.sendViewEvent(.incremented)  // arrives while .loading
        vm.sendViewEvent(.load)
        #expect(vm.viewState[case: \.success]?.count == 0)  // guard dropped it
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
