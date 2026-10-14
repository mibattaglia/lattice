import Observation
import Testing

@testable import FineGrainedExample
import Lattice

private final class ChangeProbe: @unchecked Sendable {
    var didChange = false
}

@MainActor
@Suite
struct FineGrainedExampleTests {
    private func makeViewModel() -> FineGrainedViewModel {
        ViewModel(
            initialState: FineGrainedState(),
            feature: Feature(interactor: FineGrainedInteractor())
        )
    }

    @Test
    func bumpingCountDoesNotInvalidateHeader() {
        let viewModel = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = viewModel.title } onChange: { probe.didChange = true }

        viewModel.sendViewEvent(.bumpCount)
        #expect(!probe.didChange)
        #expect(viewModel.viewState.count == 1)
    }

    @Test
    func changingTitleDoesNotInvalidateFooter() {
        let viewModel = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = viewModel.count } onChange: { probe.didChange = true }

        viewModel.sendViewEvent(.setTitle("Updated"))
        #expect(!probe.didChange)
        #expect(viewModel.viewState.title == "Updated")
    }

    @Test
    func togglingPhaseInvalidatesPhaseObserver() {
        let viewModel = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = viewModel.phase } onChange: { probe.didChange = true }

        viewModel.sendViewEvent(.togglePhase)
        #expect(probe.didChange)
        #expect(viewModel.viewState.phase == .active("Active!"))
    }
}
