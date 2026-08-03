// Exhaustivity scenarios — the exhaustivity scope
// covers both buffered actions and pending commits.

import CasePaths
import Foundation
import Testing

@testable import Lattice

private struct ExhaustivityState: Equatable {
    var values: [Int] = []
    var resetCount = 0
}

@CasePathable
private enum ExhaustivityAction: Equatable {
    case startSequence
    case step(Int)
    case reset
}

private struct ExhaustivityInteractor: Interactor {
    var body: some Interactor<ExhaustivityState, ExhaustivityAction> {
        Interact { state, action, effects in
            switch action {
            case .startSequence:
                effects.perform { effectState in
                    try effectState.send(.step(1))
                    try effectState.send(.step(2))
                }

            case .step(let value):
                state.values.append(value)

            case .reset:
                state.values = []
                state.resetCount += 1
            }
        }
    }
}

extension TestingInfrastructureTests {
    @Suite
    @MainActor
    struct TestViewModelExhaustivityTests {
    @Test
    func exhaustiveSendRequiresPendingCommitsToBeAssertedFirst() async {
        let model = makeModel()

        let task = await model.send(.startSequence)
        await task.finish()

        let sendLine = #line + 1
        await expectIssue(containing: "Must assert 2 pending commits before sending another action", line: sendLine) { _ = await model.send(.reset) }

        model.skipPendingCommits()
    }

    @Test
    func nonExhaustiveReceiveCanSkipEarlierPendingCommits() async {
        let model = makeModel()
        model.exhaustivity = .off()

        _ = await model.send(.startSequence)

        await model.receive(.step(2)) {
            $0.values = [1, 2]
        }

        #expect(model.domainState.values == [1, 2])
    }

    @Test
    func skipPendingCommitsAdvancesToLatestCommittedState() async {
        let model = makeModel()

        _ = await model.send(.startSequence)
        model.skipPendingCommits()

        #expect(model.domainState.values == [1, 2])
    }

    @Test
    func skipPendingCommitsReportsWhenNothingIsPending() async {
        let model = makeModel()

        let skipLine = #line + 1
        await expectIssue(comment: "There were no pending commits to skip.", line: skipLine) { model.skipPendingCommits() }
    }

    @Test
    func finishReportsUnassertedCommitsAtCaller() async {
        let model = makeModel()

        _ = await model.send(.startSequence)

        let finishLine = #line + 1
        await expectIssue(containing: "left unasserted", line: finishLine) { await model.finish() }

        model.skipPendingCommits()
    }

    @Test
    func dismountReportsUnassertedCommitsAndClearsThem() async {
        let model = makeModel()

        _ = await model.send(.startSequence)

        let dismountLine = #line + 1
        await expectIssue(containing: "left unasserted", line: dismountLine) { await model.dismount() }

        // dismount cleared the pending commits; the deinit backstop stays silent.
    }

    private func makeModel() -> TestViewModel<ExhaustivityState, ExhaustivityAction> {
        TestViewModel(
            initialDomainState: ExhaustivityState(),
            interactor: ExhaustivityInteractor()
        )
    }
}
}
