// Reentrancy behavior. No exclusivity trap exists here: a formal access on `_viewState`
// open during reduce cannot happen without a working copy — nothing fires at `willSet`,
// and `_commit` diffs two value copies while the registrar side table is separate from the
// state. This suite pins the remaining contract: synchronous observers notified mid-commit.

import Foundation
import Observation
import Testing

@testable import Lattice

@FeatureState
private struct ReentrancyState {
    var count: Int = 0
    var mirror: Int = -1
}

private enum ReentrancyEvent {
    case increment
    case mirror(Int)
}

private struct ReentrancyInteractor: Interactor {
    var body: some Interactor<ReentrancyState, ReentrancyEvent> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
            case .mirror(let value):
                state.mirror = value
            }
        }
    }
}

// MainActor-confined by usage; `@unchecked Sendable` so the observer closure may capture it.
private final class ReentrancyRecorder: @unchecked Sendable {
    var observedCounts: [Int] = []
    var reentrantEventTask: EventTask?
}

@MainActor
@Suite
struct ViewModelReentrancyTests {

    /// A synchronous observer reads the projection mid-commit: it sees the committed value
    /// (the registrar fires after the state value is committed) and nothing traps — there is
    /// no working copy and no formal access open on observable storage while observers run.
    @Test
    func synchronousObserverReadsCommittedValuesMidCommit() {
        let viewModel = ViewModel(
            initialState: ReentrancyState(),
            interactor: ReentrancyInteractor()
        )
        let recorder = ReentrancyRecorder()

        withObservationTracking {
            _ = viewModel.count
        } onChange: {
            MainActor.assumeIsolated {
                recorder.observedCounts.append(viewModel.count)
            }
        }

        viewModel.sendViewEvent(.increment)

        #expect(recorder.observedCounts == [1])
        #expect(viewModel.count == 1)
    }

    /// A synchronous observer calls `sendViewEvent` mid-commit: the send runs as a plain
    /// synchronous recursion — its own full update and commit — and both states are correct
    /// when the outer send returns. No reentrancy crash, no deferral.
    @Test
    func synchronousObserverSendsMidCommitRunsRecursively() {
        let viewModel = ViewModel(
            initialState: ReentrancyState(),
            interactor: ReentrancyInteractor()
        )
        let recorder = ReentrancyRecorder()

        withObservationTracking {
            _ = viewModel.count
        } onChange: {
            MainActor.assumeIsolated {
                recorder.reentrantEventTask = viewModel.sendViewEvent(
                    .mirror(viewModel.count)
                )
            }
        }

        viewModel.sendViewEvent(.increment)

        // The recursive send committed synchronously, before the outer send returned.
        #expect(viewModel.count == 1)
        #expect(viewModel.mirror == 1)
        #expect(recorder.reentrantEventTask != nil)
        #expect(recorder.reentrantEventTask?.hasEffects == false)
    }
}
