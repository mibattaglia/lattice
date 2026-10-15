import CasePaths
import Foundation
import Observation
import Testing

@testable import Lattice

@FeatureState struct SuccessState: Equatable, Sendable {
    var title: String
    var count: Int
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

@Interactor<SuccessState, SuccessAction>
private struct SuccessInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .titleChanged(let title): state.title = title
            case .incremented: state.count += 1
            }
        }
    }
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

/// A struct state holding the enum, for enum scoping through a `ScopedViewModel`.
@FeatureState private struct PhaseHostState: Equatable, Sendable {
    var phase: PhaseState = .loading
}

@CasePathable private enum PhaseHostAction: Sendable {
    case phase(PhaseAction)
}

@Interactor<PhaseHostState, PhaseHostAction>
private struct PhaseHostInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interactors.When(state: \.phase, action: \.phase) {
            PhaseInteractor()
        }
    }
}

@MainActor
@Suite struct EnumCaseScopingTests {
    private func makeViewModel(
        areStatesEqual: ((PhaseState, PhaseState) -> Bool)? = { $0 == $1 }
    ) -> ViewModel<Feature<PhaseAction, PhaseState>> {
        ViewModel(
            initialState: .loading,
            feature: Feature(interactor: PhaseInteractor(), areStatesEqual: areStatesEqual)
        )
    }

    // MARK: Root observation

    // A payload-less case has a stable identity, so reassigning it is not a replacement even
    // without state equality to swallow it.
    @Test func payloadlessCaseReassignmentDoesNotFireCoarse() {
        let vm = makeViewModel(areStatesEqual: nil)  // .loading
        let rootID = vm.state._$id
        let root = ObservationProbe { _ = vm.viewState }

        vm.sendViewEvent(.tick)
        #expect(!root.didFire)
        #expect(vm.state._$id == rootID)
    }

    @Test func enumCaseSwitchFiresRoot() {
        let vm = makeViewModel()
        let root = ObservationProbe { _ = vm.viewState }

        vm.sendViewEvent(.load)  // .loading -> .success
        #expect(root.didFire)
        #expect(vm.viewState[case: \.success]?.title == "t")
    }

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

    // A `switch viewModel.viewState` re-renders on case changes and on the payload members it
    // read, and on nothing else.
    @Test func switchOverViewStateTracksTheCaseAndThePayloadMembersItRead() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let readTitle: @MainActor () -> Void = {
            switch vm.viewState {
            case .loading: break
            case .success(let success): _ = success.title
            }
        }

        let afterCount = ObservationProbe(readTitle)
        vm.sendViewEvent(.success(.incremented))
        #expect(!afterCount.didFire)

        let afterTitle = ObservationProbe(readTitle)
        vm.sendViewEvent(.success(.titleChanged("new")))
        #expect(afterTitle.didFire)

        let afterReset = ObservationProbe(readTitle)
        vm.sendViewEvent(.reset)
        #expect(afterReset.didFire)
    }

    // MARK: Case scoping

    @Test func trappingScopeReadsLivePayload() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)
        #expect(success.title == "t")

        success.sendViewEvent(.titleChanged("new"))  // in place
        #expect(success.title == "new")  // live re-extraction, not a snapshot
    }

    @Test func scopeIfActiveReturnsNilForInactiveCase() {
        let vm = makeViewModel()  // .loading
        #expect(vm.scopeIfActive(state: \.success, action: \.success) == nil)

        vm.sendViewEvent(.load)
        #expect(vm.scopeIfActive(state: \.success, action: \.success)?.title == "t")
    }

    @Test func caseFlipServesCreationSnapshotWithoutCrashing() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)

        vm.sendViewEvent(.reset)  // .success -> .loading; scope is now stale
        #expect(success.title == "t")  // creation snapshot, no trap/crash
    }

    @Test func lateSendAfterCaseFlipIsDroppedByWhen() {
        let vm = makeViewModel()
        vm.sendViewEvent(.load)
        let success = vm.scope(state: \.success, action: \.success)
        vm.sendViewEvent(.reset)

        success.sendViewEvent(.incremented)  // arrives while .loading
        #expect(vm.viewState == .loading)
        vm.sendViewEvent(.load)
        #expect(vm.viewState[case: \.success]?.count == 0)
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

    // MARK: Enum child of a scope

    @Test func scopedEnumChildScopesIntoItsActiveCase() {
        let vm = ViewModel(initialState: PhaseHostState(), feature: Feature(interactor: PhaseHostInteractor()))
        let phase = vm.scope(state: \.phase, action: \.phase)
        #expect(phase.scopeIfActive(state: \.success, action: \.success) == nil)

        phase.sendViewEvent(.load)
        let success = phase.scope(state: \.success, action: \.success)
        let title = ObservationProbe { _ = success.title }
        let coarse = ObservationProbe { _ = phase.viewState }

        success.sendViewEvent(.titleChanged("nested"))
        #expect(title.didFire)
        #expect(!coarse.didFire)
        #expect(phase.scopeIfActive(state: \.success, action: \.success)?.title == "nested")
        #expect(vm.phase[case: \.success]?.title == "nested")
    }
}
