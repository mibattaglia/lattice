import Foundation
import IdentifiedCollections
import Observation
import Testing

@testable import Lattice

@FeatureState
struct CollectionRowState: Equatable, Identifiable, Sendable {
    let id: Int
    var count = 0
}

@FeatureState
private struct CollectionState: Equatable, Sendable {
    var title = "Rows"
    var rows: [CollectionRowState] = []
    var idRows: IdentifiedArrayOf<CollectionRowState> = []
}

private enum CollectionAction: Sendable {
    case mutate(@Sendable (inout CollectionState) -> Void)
}

@Interactor<CollectionState, CollectionAction>
private struct CollectionInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action, _ in
            switch action {
            case .mutate(let mutation): mutation(&state)
            }
        }
    }
}

/// An element edit (`rows[0].count += 1`, `rows[id:]?.count += 1`) invalidates only that element's
/// readers, and `rows.append` invalidates the `rows` readers, for `Array` and `IdentifiedArrayOf`
/// collections of child states.
@MainActor
@Suite
struct ViewModelCollectionObservationTests {
    private func makeViewModel() -> ViewModel<Feature<CollectionAction, CollectionState>> {
        ViewModel(
            initialState: CollectionState(
                rows: [CollectionRowState(id: 1, count: 1), CollectionRowState(id: 2, count: 2)],
                idRows: [CollectionRowState(id: 1, count: 1), CollectionRowState(id: 2, count: 2)]
            ),
            feature: Feature(interactor: CollectionInteractor())
        )
    }

    // MARK: Array

    @Test
    func arrayElementMutationFiresOnlyThatElement() {
        let viewModel = makeViewModel()
        let first = ObservationProbe { _ = viewModel.rows[0].count }
        let second = ObservationProbe { _ = viewModel.rows[1].count }
        let rowCount = ObservationProbe { _ = viewModel.rows.count }
        let title = ObservationProbe { _ = viewModel.title }
        let root = ObservationProbe { _ = viewModel.viewState }

        viewModel.sendViewEvent(.mutate { $0.rows[0].count += 1 })

        #expect(first.didFire)
        #expect(!second.didFire)
        #expect(!rowCount.didFire)
        #expect(!title.didFire)
        #expect(!root.didFire)
        #expect(viewModel.rows[0].count == 2)
    }

    @Test
    func arrayAppendFiresRowsObservers() {
        let viewModel = makeViewModel()
        let rowCount = ObservationProbe { _ = viewModel.rows.count }
        let first = ObservationProbe { _ = viewModel.rows[0].count }  // read through `rows`
        let title = ObservationProbe { _ = viewModel.title }
        let root = ObservationProbe { _ = viewModel.viewState }

        viewModel.sendViewEvent(.mutate { $0.rows.append(CollectionRowState(id: 3)) })

        #expect(rowCount.didFire)
        #expect(first.didFire)
        #expect(!title.didFire)
        #expect(!root.didFire)
        #expect(viewModel.rows.map(\.id) == [1, 2, 3])
    }

    // MARK: IdentifiedArrayOf

    @Test
    func identifiedArrayElementMutationFiresOnlyThatElement() {
        let viewModel = makeViewModel()
        let first = ObservationProbe { _ = viewModel.idRows[0].count }
        let second = ObservationProbe { _ = viewModel.idRows[1].count }
        let rowCount = ObservationProbe { _ = viewModel.idRows.count }
        let root = ObservationProbe { _ = viewModel.viewState }

        viewModel.sendViewEvent(.mutate { $0.idRows[0].count += 1 })

        #expect(first.didFire)
        #expect(!second.didFire)
        #expect(!rowCount.didFire)
        #expect(!root.didFire)
        #expect(viewModel.idRows[0].count == 2)
    }

    @Test
    func identifiedArrayAppendFiresRowsObservers() {
        let viewModel = makeViewModel()
        let rowCount = ObservationProbe { _ = viewModel.idRows.count }
        let first = ObservationProbe { _ = viewModel.idRows[id: 1]?.count }  // read through `idRows`
        let title = ObservationProbe { _ = viewModel.title }
        let root = ObservationProbe { _ = viewModel.viewState }

        viewModel.sendViewEvent(.mutate { $0.idRows.append(CollectionRowState(id: 3)) })

        #expect(rowCount.didFire)
        #expect(first.didFire)
        #expect(!title.didFire)
        #expect(!root.didFire)
        #expect(viewModel.idRows.map(\.id) == [1, 2, 3])
        #expect(viewModel.idRows[id: 3]?.count == 0)
    }

    @Test
    func identifiedArrayIDSubscriptMutationFiresOnlyThatElement() {
        let viewModel = makeViewModel()
        let first = ObservationProbe { _ = viewModel.idRows[id: 1]?.count }
        let second = ObservationProbe { _ = viewModel.idRows[id: 2]?.count }
        let rowCount = ObservationProbe { _ = viewModel.idRows.count }
        let root = ObservationProbe { _ = viewModel.viewState }

        viewModel.sendViewEvent(.mutate { $0.idRows[id: 1]?.count += 1 })

        #expect(first.didFire)
        #expect(!second.didFire)
        #expect(!rowCount.didFire)
        #expect(!root.didFire)
        #expect(viewModel.idRows[id: 1]?.count == 2)
    }
}
