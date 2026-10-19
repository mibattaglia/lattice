import Foundation
import Testing

@testable import Lattice

/// `ViewModel` is the subject: which observations an effect's modification fires, through the root
/// state and through `When` children. The fixtures are `ModificationTests`'.
@MainActor
@Suite
struct ModificationObservationTests {
    private func makeViewModel(
        areStatesEqual: ((ModificationState, ModificationState) -> Bool)? = { $0 == $1 }
    ) -> ViewModel<Feature<ModificationAction, ModificationState>> {
        ViewModel(
            initialState: ModificationState(),
            feature: Feature(interactor: ModificationInteractor(), areStatesEqual: areStatesEqual)
        )
    }

    @Test
    func modifyNotifiesOnlyTheObserversOfTheMembersItChanges() async {
        let viewModel = makeViewModel()

        let task = viewModel.sendViewEvent(.modifyCountAndTitleAfterYield)
        let count = ObservationProbe { _ = viewModel.count }
        let title = ObservationProbe { _ = viewModel.title }
        let note = ObservationProbe { _ = viewModel.note }
        let childValue = ObservationProbe { _ = viewModel.child.value }
        let root = ObservationProbe { _ = viewModel.viewState }
        await task?.value

        #expect(count.didFire)
        #expect(title.didFire)
        #expect(!note.didFire)
        #expect(!childValue.didFire)
        #expect(!root.didFire)
        #expect(viewModel.count == 1)
        #expect(viewModel.title == "title")
    }

    @Test
    func contentEqualReplacementInModifyNotifiesNothing() async {
        let viewModel = makeViewModel()
        let rootID = viewModel.state._$id

        let task = viewModel.sendViewEvent(.replaceWithEqualContentAfterYield)
        let root = ObservationProbe { _ = viewModel.viewState }
        let count = ObservationProbe { _ = viewModel.count }
        let childValue = ObservationProbe { _ = viewModel.child.value }
        await task?.value

        #expect(!root.didFire)
        #expect(!count.didFire)
        #expect(!childValue.didFire)
        #expect(viewModel.state._$id == rootID)
    }

    /// Control for the test above: the same replacement goes through the commit's state-equality gate.
    @Test
    func contentEqualReplacementInModifyNotifiesTheRootWithoutStateEquality() async {
        let viewModel = makeViewModel(areStatesEqual: nil)

        let task = viewModel.sendViewEvent(.replaceWithEqualContentAfterYield)
        let root = ObservationProbe { _ = viewModel.viewState }
        await task?.value

        #expect(root.didFire)
    }

    @Test
    func childModifyIsWrittenBackThroughAWhenKeyPath() async {
        let viewModel = makeViewModel()

        let task = viewModel.sendViewEvent(.child(.bumpAfterYield))
        let childValue = ObservationProbe { _ = viewModel.child.value }
        let count = ObservationProbe { _ = viewModel.count }
        let root = ObservationProbe { _ = viewModel.viewState }
        await task?.value

        #expect(viewModel.child.value == 1)
        #expect(childValue.didFire)
        #expect(!count.didFire)
        #expect(!root.didFire)
    }

    @Test
    func childModifyIsWrittenBackThroughAWhenCasePath() async {
        let viewModel = ViewModel(
            initialState: GatedModeState.active(GatedChildState(value: 0)),
            feature: Feature(interactor: GatedModeInteractor())
        )
        let rootID = viewModel.state._$id

        let task = viewModel.sendViewEvent(.active(.bumpAfterYield))
        let root = ObservationProbe { _ = viewModel.viewState }
        #expect(viewModel.state == .active(GatedChildState(value: 0)))
        await task?.value

        #expect(viewModel.state == .active(GatedChildState(value: 1)))
        #expect(!root.didFire)
        #expect(viewModel.state._$id == rootID)
    }
}
