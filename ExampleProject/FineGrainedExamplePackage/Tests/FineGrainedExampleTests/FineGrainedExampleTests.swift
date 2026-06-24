import Foundation
import Observation
import Testing

@testable import FineGrainedExample
import Lattice

private final class ChangeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hasChanged = false
    var didChange: Bool { lock.withLock { hasChanged } }
    func mark() { lock.withLock { hasChanged = true } }
}

@MainActor
@Suite
struct FineGrainedExampleTests {
    private func makeViewModel() -> FineGrainedViewModel {
        ViewModel(
            initialDomainState: FineGrainedDomainState(),
            feature: Feature(
                interactor: FineGrainedInteractor(),
                reducer: FineGrainedViewStateReducer()
            )
        )
    }

    @Test
    func bumpingCountDoesNotInvalidateHeader() {
        let viewModel = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = viewModel.header.title } onChange: { probe.mark() }

        viewModel.sendViewEvent(.bumpCount)
        #expect(!probe.didChange)
        #expect(viewModel.viewState.footer.count == 1)
    }

    @Test
    func changingTitleDoesNotInvalidateFooter() {
        let viewModel = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = viewModel.footer.count } onChange: { probe.mark() }

        viewModel.sendViewEvent(.setTitle("Updated"))
        #expect(!probe.didChange)
        #expect(viewModel.viewState.header.title == "Updated")
    }

    @Test
    func togglingPhaseInvalidatesPhaseObserver() {
        let viewModel = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = viewModel.phase } onChange: { probe.mark() }

        viewModel.sendViewEvent(.togglePhase)
        #expect(probe.didChange)
        #expect(viewModel.viewState.phase == .active("Active!"))
    }
}
