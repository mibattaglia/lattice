import CasePaths
import Foundation
import Observation
import Testing

@testable import Lattice

@MainActor
@Suite
struct ViewModelReentrancyTests {
    // A tracked mutation fires the observation `willSet` synchronously, so an observer (such as
    // SwiftUI re-evaluating `body`) can re-read the view model while the action is still running.
    // That re-read must not trap with an exclusive-access conflict, and it sees the previous
    // committed value, because the interactor mutates a working copy of the state.
    @Test
    func synchronousReadDuringMutationSeesThePreviousCommittedValue() {
        let viewModel = makeViewModel()
        let seen = SeenValues()

        withObservationTracking {
            _ = viewModel.phase
        } onChange: {
            // Re-enter the getters synchronously, exactly as SwiftUI body re-evaluation can.
            MainActor.assumeIsolated {
                _ = viewModel.viewState
                seen.record(phaseValue: viewModel.phase[case: \.active]?.value)
            }
        }

        viewModel.sendViewEvent(.increment)

        #expect(seen.phaseValue == "0")
        #expect(viewModel.phase[case: \.active]?.value == "1")
    }

    @Test
    func synchronousReadDuringLeafMutationSeesThePreviousCommittedValues() {
        let viewModel = makeViewModel()
        let seen = SeenValues()

        withObservationTracking {
            _ = viewModel.count
        } onChange: {
            MainActor.assumeIsolated {
                seen.record(title: viewModel.title, count: viewModel.count)
            }
        }

        // Writes `title` first, then `count`: the observer runs while the working copy already
        // holds the new title.
        viewModel.sendViewEvent(.renameAndIncrement("During"))

        #expect(seen.title == "Counter")
        #expect(seen.count == 0)
        #expect(viewModel.title == "During")
        #expect(viewModel.count == 1)
    }

    private func makeViewModel() -> ViewModel<Feature<CounterPhaseAction, CounterPhaseState>> {
        ViewModel(initialState: CounterPhaseState(), feature: Feature(interactor: CounterPhaseInteractor()))
    }
}

private final class SeenValues: @unchecked Sendable {
    private let lock = NSLock()
    private var _phaseValue: String?
    private var _title: String?
    private var _count: Int?

    var phaseValue: String? { lock.withLock { _phaseValue } }
    var title: String? { lock.withLock { _title } }
    var count: Int? { lock.withLock { _count } }

    func record(phaseValue: String?) {
        lock.withLock { _phaseValue = phaseValue }
    }

    func record(title: String, count: Int) {
        lock.withLock {
            _title = title
            _count = count
        }
    }
}

@FeatureState
struct CounterPhasePayload: Equatable, Sendable {
    var value: String
}

@FeatureState
private struct CounterPhaseState: Equatable, Sendable {
    var title = "Counter"
    var count = 0
    var phase: CounterPhase = .active(CounterPhasePayload(value: "0"))
}

private enum CounterPhaseAction: Sendable {
    case increment
    case renameAndIncrement(String)
}

@Interactor<CounterPhaseState, CounterPhaseAction>
private struct CounterPhaseInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                state.phase = .active(CounterPhasePayload(value: "\(state.count)"))
            case .renameAndIncrement(let title):
                state.title = title
                state.count += 1
            }
            return .none
        }
    }
}
