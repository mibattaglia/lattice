import CasePaths
import Foundation
import Observation
import Testing

@testable import Lattice

@FeatureState
struct ObservationTestPayload: Equatable, Sendable {
    var value: String
}

@FeatureState
struct ObservedBadgeState: Equatable, Sendable {
    var label = "Badge"
    var count = 0
}

@FeatureState
private struct ObservedState: Equatable, Sendable {
    var title = "Counter"
    var badge = ObservedBadgeState()
    var detail: ObservedBadgeState?
    var phase: ObservationTestPhase = .active(ObservationTestPayload(value: "0"))
}

private enum ObservedAction: Sendable {
    case mutate(@Sendable (inout ObservedState) -> Void)
}

@Interactor<ObservedState, ObservedAction>
private struct ObservedInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action, _ in
            switch action {
            case .mutate(let mutation): mutation(&state)
            }
        }
    }
}

@MainActor
@Suite
struct ViewModelObservationTests {
    private func makeViewModel(
        areStatesEqual: ((ObservedState, ObservedState) -> Bool)? = { $0 == $1 }
    ) -> ViewModel<Feature<ObservedAction, ObservedState>> {
        ViewModel(
            initialState: ObservedState(),
            feature: Feature(interactor: ObservedInteractor(), areStatesEqual: areStatesEqual)
        )
    }

    // MARK: Enum members

    @Test
    func directAssignmentOfEnumMemberInvalidatesPhaseObservation() {
        let viewModel = makeViewModel()
        let phase = ObservationProbe { _ = viewModel.phase }

        viewModel.sendViewEvent(.mutate { $0.phase = .active(ObservationTestPayload(value: "1")) })

        #expect(phase.didFire)
        #expect(viewModel.phase[case: \.active]?.value == "1")
    }

    // Fine-grained observation: an in-place payload mutation (case unchanged) does NOT fire the
    // coarse `\.phase` key path, so an observer that reads only the *whole* enum is not
    // invalidated. Real views read the payload leaf (see
    // `casePathMutationInvalidatesNestedValueObservation`) and do re-render.
    @Test
    func casePathMutationDoesNotInvalidateWholePhaseObservation() {
        let viewModel = makeViewModel()
        let phase = ObservationProbe { _ = viewModel.phase }

        viewModel.sendViewEvent(.mutate { $0.phase.modify(\.active) { $0.value = "1" } })

        #expect(!phase.didFire)
        #expect(viewModel.phase[case: \.active]?.value == "1")
    }

    @Test
    func casePathMutationInvalidatesNestedValueObservation() {
        let viewModel = makeViewModel()
        let value = ObservationProbe { _ = viewModel.phase[case: \.active]?.value }

        viewModel.sendViewEvent(.mutate { $0.phase.modify(\.active) { $0.value = "1" } })

        #expect(value.didFire)
        #expect(viewModel.phase[case: \.active]?.value == "1")
    }

    // MARK: Root gate

    @Test
    func wholesaleReplacementWithDifferentContentFiresRootAndEveryLeaf() {
        let viewModel = makeViewModel()
        let root = ObservationProbe { _ = viewModel.viewState }
        let title = ObservationProbe { _ = viewModel.title }
        let badgeCount = ObservationProbe { _ = viewModel.badge.count }

        viewModel.sendViewEvent(.mutate { $0 = ObservedState(title: "Other") })

        #expect(root.didFire)
        #expect(title.didFire)
        #expect(badgeCount.didFire)
        #expect(viewModel.title == "Other")
    }

    @Test
    func wholesaleReplacementWithEqualContentIsSilentAndPreservesRegistrars() {
        let viewModel = makeViewModel()
        let rootID = viewModel.state._$id
        let badgeID = viewModel.state.badge._$id
        let root = ObservationProbe { _ = viewModel.viewState }
        let title = ObservationProbe { _ = viewModel.title }
        let badgeCount = ObservationProbe { _ = viewModel.badge.count }

        viewModel.sendViewEvent(.mutate { $0 = ObservedState() })  // equal content, new registrars

        #expect(!root.didFire)
        #expect(!title.didFire)
        #expect(!badgeCount.didFire)
        #expect(viewModel.state._$id == rootID)
        #expect(viewModel.state.badge._$id == badgeID)

        // The observers registered before the replacement still track the kept registrars.
        viewModel.sendViewEvent(.mutate { $0.badge.count += 1 })
        #expect(badgeCount.didFire)
        #expect(!root.didFire)
    }

    @Test
    func wholesaleReplacementWithEqualContentFiresRootWithoutStateEquality() {
        let viewModel = makeViewModel(areStatesEqual: nil)
        let root = ObservationProbe { _ = viewModel.viewState }

        viewModel.sendViewEvent(.mutate { $0 = ObservedState() })

        #expect(root.didFire)
    }

    // MARK: Children

    @Test
    func contentEqualChildRebuildIsSilentAndPreservesTheChildID() {
        let viewModel = makeViewModel()
        let badgeID = viewModel.state.badge._$id
        let root = ObservationProbe { _ = viewModel.viewState }
        let badge = ObservationProbe { _ = viewModel.badge }
        let count = ObservationProbe { _ = viewModel.badge.count }

        viewModel.sendViewEvent(.mutate { $0.badge = ObservedBadgeState() })

        #expect(!root.didFire)
        #expect(!badge.didFire)
        #expect(!count.didFire)
        #expect(viewModel.state.badge._$id == badgeID)
    }

    @Test
    func childRebuiltWithDifferentContentFiresObserversThroughTheChild() {
        let viewModel = makeViewModel()
        let root = ObservationProbe { _ = viewModel.viewState }
        let count = ObservationProbe { _ = viewModel.badge.count }
        let label = ObservationProbe { _ = viewModel.badge.label }  // unchanged, read through badge
        let title = ObservationProbe { _ = viewModel.title }

        viewModel.sendViewEvent(.mutate { $0.badge = ObservedBadgeState(count: 99) })

        #expect(count.didFire)
        #expect(label.didFire)
        #expect(!title.didFire)
        #expect(!root.didFire)
        #expect(viewModel.badge.count == 99)
    }

    @Test
    func optionalChildInsertionFiresThenInPlaceLeafMutationIsLeafOnly() {
        let viewModel = makeViewModel()
        let detail = ObservationProbe { _ = viewModel.detail?.count }
        let title = ObservationProbe { _ = viewModel.title }

        viewModel.sendViewEvent(.mutate { $0.detail = ObservedBadgeState(count: 1) })

        #expect(detail.didFire)
        #expect(!title.didFire)

        let count = ObservationProbe { _ = viewModel.detail?.count }
        let label = ObservationProbe { _ = viewModel.detail?.label }
        let root = ObservationProbe { _ = viewModel.viewState }

        viewModel.sendViewEvent(.mutate { $0.detail?.count += 1 })

        #expect(count.didFire)
        #expect(!label.didFire)
        #expect(!root.didFire)
        #expect(viewModel.detail?.count == 2)
    }
}
