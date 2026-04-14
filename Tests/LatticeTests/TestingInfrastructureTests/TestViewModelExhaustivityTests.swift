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

        let task = try? await model.send(.startSequence)
        try? await task?.finish()

        await expectTestFailure(containing: "Must handle received actions before sending") {
            _ = try await model.send(.reset)
        }
    }

    @Test
    func nonExhaustiveReceiveCanSkipEarlierBufferedActions() async throws {
        let model = makeModel()
        model.exhaustivity = .off()

        _ = try await model.send(.startSequence)

        try await model.receive(.step(2)) {
            $0.values = [1, 2]
        }

        #expect(model.domainState.values == [1, 2])
    }

    @Test
    func skipReceivedActionsAdvancesToLatestBufferedState() async throws {
        let model = makeModel()

        _ = try await model.send(.startSequence)
        try await model.skipReceivedActions()

        #expect(model.domainState.values == [1, 2])
    }

    @Test
    func finishFailsWhileReceivedActionsRemainUnhandled() async {
        let model = makeModel()

        _ = try? await model.send(.startSequence)

        await expectTestFailure(containing: "left unhandled") {
            try await model.finish()
        }
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
