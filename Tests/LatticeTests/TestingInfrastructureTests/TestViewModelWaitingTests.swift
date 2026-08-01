// Plan 07 §9: waiting/timeout scenarios migrated from the Emission-era suite. Timing-based
// fixtures keep real clocks deliberately: they exercise the host's deadline machinery itself.

import Foundation
import Testing

@testable import Lattice

private struct WaitingState: Equatable {
    var count = 0
}

private enum WaitingAction: Equatable {
    case increment
    case startDelayedLoad(Duration)
    case startNever
    case loaded(Int)
}

private struct WaitingInteractor: Interactor {
    var body: some Interactor<WaitingState, WaitingAction> {
        Interact { state, action, effects in
            switch action {
            case .increment:
                state.count += 1

            case .startDelayedLoad(let duration):
                effects.perform { effectState in
                    try await Task.sleep(for: duration)
                    try effectState.send(.loaded(41))
                }

            case .startNever:
                effects.perform { _ in
                    try await Task.sleep(for: .seconds(60))
                }

            case .loaded(let value):
                state.count += value
            }
        }
    }
}

extension TestingInfrastructureTests {
    @Suite
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

        // Wide margin over the 10ms receive timeout below so a loaded parallel test run cannot
        // deliver the action before the timeout fires. The effect is cancelled at the end,
        // so the test never actually waits this long.
        let task = await model.send(.startDelayedLoad(.seconds(5)))

        let matchesReceiveTimeout: @Sendable (Issue) -> Bool = { issue in
            issue.description.contains("but none arrived after 0.01 seconds")
                && issue.description.contains("loaded(41)")
        }
        let receiveLine = #line + 2
        await expectIssue(line: receiveLine, matching: matchesReceiveTimeout) {
            await model.receive(.loaded(41), timeout: .milliseconds(10))
        }

        await task.cancel()
    }

    @Test
    func finishReportsTimeoutWhileEffectRemainsInFlight() async {
        let model = makeModel()

        let task = await model.send(.startNever)

        let finishLine = #line + 1
        await expectIssue(containing: "Expected effects to finish, but in-flight effects remained after 0.01 seconds.", line: finishLine) { await model.finish(timeout: .milliseconds(10)) }

        await task.cancel()
    }

    @Test
    func finishReportsPendingCommitsProducedWhileWaiting() async {
        let model = makeModel()

        let task = await model.send(.startDelayedLoad(.milliseconds(50)))

        let matchesPendingCommitFailure: @Sendable (Issue) -> Bool = { issue in
            issue.description.contains("1 pending commit left unasserted.")
                && issue.description.contains("loaded(41)")
        }
        let finishLine = #line + 2
        await expectIssue(line: finishLine, matching: matchesPendingCommitFailure) {
            await model.finish(timeout: .seconds(1))
        }

        #expect(model.domainState.count == 0)

        await model.receive(.loaded(41)) {
            $0.count = 41
        }

        await task.finish()
    }

    private func makeModel() -> TestViewModel<WaitingState, WaitingAction> {
        TestViewModel(
            initialDomainState: WaitingState(),
            interactor: WaitingInteractor()
        )
    }
}
}
