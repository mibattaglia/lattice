import Foundation
import Testing

@testable import Lattice

@ObservableState
private struct ExhaustivityState: Equatable, Sendable {
    var values: [Int] = []
    var resetCount = 0
}

private enum ExhaustivityAction: Equatable, Sendable {
    case startSequence
    case step(Int)
    case reset
}

@Interactor<ExhaustivityState, ExhaustivityAction>
private struct ExhaustivityInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .startSequence:
                return .append(
                    .action(.step(1)),
                    .action(.step(2))
                )

            case .step(let value):
                state.values.append(value)
                return .none

            case .reset:
                state.values = []
                state.resetCount += 1
                return .none
            }
        }
    }
}

@Suite
@MainActor
struct TestViewModelExhaustivityTests {
    @Test
    func exhaustiveSendRequiresPendingReceivesToBeHandledFirst() async {
        let model = makeModel()

        let task = await model.send(.startSequence)
        await task.finish()

        let sendLine = #line + 1
        await expectIssue(containing: "Must handle 2 received actions before sending another action", line: sendLine) { _ = await model.send(.reset) }
    }

    @Test
    func nonExhaustiveReceiveCanSkipEarlierBufferedActions() async {
        let model = makeModel()
        model.exhaustivity = .off()

        _ = await model.send(.startSequence)

        await model.receive(.step(2)) {
            $0.values = [1, 2]
        }

        #expect(model.domainState.values == [1, 2])
    }

    @Test
    func skipReceivedActionsAdvancesToLatestBufferedState() async {
        let model = makeModel()

        _ = await model.send(.startSequence)
        await model.skipReceivedActions()

        #expect(model.domainState.values == [1, 2])
    }

    @Test
    func finishReportsUnhandledReceivedActionsAtCaller() async {
        let model = makeModel()

        _ = await model.send(.startSequence)

        let finishLine = #line + 1
        await expectIssue(containing: "left unhandled", line: finishLine) { await model.finish() }
    }

    private func makeModel()
        -> TestViewModel<Feature<ExhaustivityAction, ExhaustivityState, ExhaustivityState>>
    {
        TestViewModel(
            initialDomainState: ExhaustivityState(),
            feature: Feature(interactor: ExhaustivityInteractor())
        )
    }
}
