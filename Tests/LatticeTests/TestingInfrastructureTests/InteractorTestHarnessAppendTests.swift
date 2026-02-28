import Testing

@testable import Lattice

@Suite(.serialized)
@MainActor
struct InteractorTestHarnessAppendTests {

    @Interactor
    struct SequenceInteractor {
        struct State: Equatable, Sendable {
            var values: [Int] = []
        }

        enum Action: Sendable, Equatable {
            case runSequence
            case add(Int)
        }

        var body: some Interactor<State, Action> {
            Interact { state, action in
                switch action {
                case .runSequence:
                    return .append(
                        .perform {
                            try? await Task.sleep(for: .milliseconds(5))
                            return .add(1)
                        },
                        .perform {
                            try? await Task.sleep(for: .milliseconds(5))
                            return .add(2)
                        },
                        .perform {
                            try? await Task.sleep(for: .milliseconds(5))
                            return .add(3)
                        }
                    )

                case .add(let value):
                    state.values.append(value)
                    return .none
                }
            }
        }
    }

    @Test
    func sendAndFinishMirrorsViewModelOrdering() async throws {
        let harness = InteractorTestHarness(
            initialState: SequenceInteractor.State(),
            interactor: SequenceInteractor()
        )

        await harness.send(.runSequence).finish()

        #expect(harness.currentState.values == [1, 2, 3])
    }

    @Test
    func actionHistoryRecordsAllActions() async throws {
        let harness = InteractorTestHarness(
            initialState: SequenceInteractor.State(),
            interactor: SequenceInteractor()
        )

        await harness.send(.runSequence).finish()

        try harness.assertActions([
            .runSequence,
            .add(1),
            .add(2),
            .add(3),
        ])
    }

    @Test
    func stateHistoryRecordsEachStep() async throws {
        let harness = InteractorTestHarness(
            initialState: SequenceInteractor.State(),
            interactor: SequenceInteractor()
        )

        await harness.send(.runSequence).finish()

        try harness.assertStates([
            SequenceInteractor.State(values: []),
            SequenceInteractor.State(values: [1]),
            SequenceInteractor.State(values: [1, 2]),
            SequenceInteractor.State(values: [1, 2, 3]),
        ])
    }

    @Test
    func parentCancellationStopsRemainingSteps() async throws {
        let harness = InteractorTestHarness(
            initialState: SequenceInteractor.State(),
            interactor: SequenceInteractor()
        )

        let task = harness.send(.runSequence)
        task.cancel()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(harness.currentState.values.count < 3)
    }
}
