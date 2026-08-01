import Foundation
import Observation
import Testing

@testable import FineGrainedExample
import Lattice

// Sendable here is an Observation-API requirement (withObservationTracking's onChange
// closure is @Sendable), not a Lattice one — Lattice itself imposes no Sendable constraints.
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
            initialState: FineGrainedState(),
            interactor: FineGrainedInteractor()
        )
    }

    @Test
    func bumpingCountDoesNotInvalidateTitle() {
        let viewModel = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = viewModel.title } onChange: { probe.mark() }

        viewModel.sendViewEvent(.bumpCount)
        #expect(!probe.didChange)
        #expect(viewModel.count == 1)
    }

    @Test
    func changingTitleDoesNotInvalidateCount() {
        let viewModel = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = viewModel.count } onChange: { probe.mark() }

        viewModel.sendViewEvent(.setTitle("Updated"))
        #expect(!probe.didChange)
        #expect(viewModel.title == "Updated")
    }

    @Test
    func togglingPhaseInvalidatesPhaseObserver() {
        let viewModel = makeViewModel()
        let probe = ChangeProbe()
        withObservationTracking { _ = viewModel.phaseLabel } onChange: { probe.mark() }

        viewModel.sendViewEvent(.togglePhase)
        #expect(probe.didChange)
        #expect(viewModel.phaseLabel == "Active!")
    }
}
