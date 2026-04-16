import Foundation
import Testing

@testable import Lattice

@ObservableState
private struct WaitingState: Equatable, Sendable {
    var count = 0
}

private enum WaitingAction: Equatable, Sendable {
    case increment
    case startDelayedLoad(Duration)
    case startNever
    case loaded(Int)
}

@Interactor<WaitingState, WaitingAction>
private struct WaitingInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none

            case .startDelayedLoad(let duration):
                return .perform {
                    do {
                        try await Task.sleep(for: duration)
                    } catch {
                        return nil
                    }

                    return .loaded(41)
                }

            case .startNever:
                return .perform {
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        return nil
                    }

                    return nil
                }

            case .loaded(let value):
                state.count += value
                return .none
            }
        }
    }
}

@Suite(.serialized)
@MainActor
struct TestViewModelWaitingTests {
    @Test
    func sendWithoutEffectsReturnsImmediateTask() async {
        let model = makeModel()

        let task = await model.send(.increment) {
            $0.count = 1
        }

        #expect(task.hasEffects == false)

        await task.finish(timeout: .milliseconds(0))

        #expect(model.domainState.count == 1)
    }

    @Test
    func receiveWaitsForDelayedActionWithinTimeout() async {
        let model = makeModel()

        let task = await model.send(.startDelayedLoad(.milliseconds(50)))

        await model.receive(.loaded(41), timeout: .seconds(1)) {
            $0.count = 41
        }

        await task.finish()

        #expect(model.domainState.count == 41)
    }

    @Test
    func receiveReportsTimeoutWhileActionRemainsInFlight() async {
        let model = makeModel()

        let task = await model.send(.startDelayedLoad(.milliseconds(200)))

        let matchesReceiveTimeout: @Sendable (Issue) -> Bool = { issue in
            issue.description.contains("Expected to receive the following action, but didn't after 0.01 seconds")
                && issue.description.contains("loaded(41)")
                && issue.description.contains("There are emissions in flight")
        }
        let receiveLine = #line + 2
        await expectIssue(line: receiveLine, matching: matchesReceiveTimeout) {
            await model.receive(.loaded(41), timeout: .milliseconds(10))
        }

        await task.cancel()
    }

    @Test
    func finishReportsTimeoutWhileEmissionRemainsInFlight() async {
        let model = makeModel()

        let task = await model.send(.startNever)

        let finishLine = #line + 1
        await expectIssue(containing: "Expected emissions to finish, but 1 emission remained in flight after 0.01 seconds.", line: finishLine) { await model.finish(timeout: .milliseconds(10)) }

        await task.cancel()
    }

    @Test
    func finishReportsBufferedReceivesProducedWhileWaiting() async {
        let model = makeModel()

        let task = await model.send(.startDelayedLoad(.milliseconds(50)))

        let matchesBufferedReceiveFailure: @Sendable (Issue) -> Bool = { issue in
            issue.description.contains("Received 1 unexpected action left unhandled.")
                && issue.description.contains("loaded(41)")
        }
        let finishLine = #line + 2
        await expectIssue(line: finishLine, matching: matchesBufferedReceiveFailure) {
            await model.finish(timeout: .seconds(1))
        }

        #expect(model.domainState.count == 0)

        await model.receive(.loaded(41)) {
            $0.count = 41
        }

        await task.finish()
    }

    private func makeModel() -> TestViewModel<TestSupportFeature<WaitingAction, WaitingState>> {
        makeTestViewModel(
            initialDomainState: WaitingState(),
            interactor: WaitingInteractor()
        )
    }
}
