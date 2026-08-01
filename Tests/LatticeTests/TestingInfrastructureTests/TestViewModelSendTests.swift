// Plan 07 §8-§9: the send/expect/receive contract on the rewritten host. Scenarios migrated
// from the Emission-era suite: effects commit state directly (asserted with `expect`);
// `receive` covers genuine `effectState.send` re-entries.

import CasePaths
import Foundation
import Testing

@testable import Lattice

private struct TestSendState: Equatable {
    var count = 0
}

@CasePathable
private enum TestSendAction: Equatable {
    case increment
    case load
    case loadViaAction
    case loaded(Int)
}

private struct TestSendInteractor: Interactor {
    var body: some Interactor<TestSendState, TestSendAction> {
        Interact { state, action, effects in
            switch action {
            case .increment:
                state.count += 1

            case .load:
                state.count += 1
                // The effect commits state directly — no .loaded ping-pong.
                effects.perform { effectState in
                    try effectState.modify { $0.count += 41 }
                }

            case .loadViaAction:
                state.count += 1
                // Parent-notification pattern: a genuine re-entry via effectState.send.
                effects.perform { effectState in
                    try effectState.send(.loaded(41))
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
    struct TestViewModelSendTests {
    @Test
    func sendCommitsEffectMutationsForAssertion() async {
        let model = makeModel()

        let task = await model.send(.load) {
            $0.count = 1
        }

        #expect(task.hasEffects)

        await model.expect {
            $0.count = 42
        }

        #expect(model.domainState.count == 42)
    }

    @Test
    func sendWithoutChangesAssertsNoVisibleChange() async {
        let model = makeModel()

        _ = await model.send(.increment) { $0.count = 1 }
        // A send whose update phase mutates nothing visible needs no trailing closure —
        // but the commit is still consumed.
        let sendLine = #line + 1
        await expectIssue(containing: "State was not expected to change", line: sendLine) { _ = await model.send(.increment) }
    }

    @Test
    func receiveAssertsEffectSendReentries() async {
        let model = makeModel()

        let task = await model.send(.loadViaAction) {
            $0.count = 1
        }

        #expect(task.hasEffects)

        await model.receive(.loaded(41)) {
            $0.count = 42
        }

        #expect(model.domainState.count == 42)
    }

    @Test
    func receiveSupportsCasePathMatching() async {
        let model = makeModel()

        _ = await model.send(.loadViaAction) {
            $0.count = 1
        }

        await model.receive(\.loaded) {
            $0.count = 42
        }

        #expect(model.domainState.count == 42)
    }

    @Test
    func sendFailureIncludesStateDiffAndCallerAttribution() async {
        let model = makeModel()
        let matchesSendIssue: @Sendable (Issue) -> Bool = { issue in
            issue.description.contains("A state change does not match expectation.")
                && issue.description.contains("count: 999")
                && issue.description.contains("count: 1")
                && issue.description.contains("(Expected: −, Actual: +)")
        }
        let sendLine = #line + 1
        await expectIssue(line: sendLine, matching: matchesSendIssue) { _ = await model.send(.load) { $0.count = 999 } }

        // The effect's mutation commit is still pending; consume it.
        await model.expect { $0.count = 42 }
    }

    @Test
    func receiveFailureIncludesActionDiffAndCallerAttribution() async {
        let model = makeModel()
        _ = await model.send(.loadViaAction) {
            $0.count = 1
        }
        let matchesReceiveIssue: @Sendable (Issue) -> Bool = { issue in
            issue.description.contains("Received unexpected action")
                && issue.description.contains("increment")
                && issue.description.contains("loaded(41)")
                && issue.description.contains("(Expected: −, Received: +)")
        }
        let receiveLine = #line + 1
        await expectIssue(line: receiveLine, matching: matchesReceiveIssue) { await model.receive(.increment) }
    }

    private func makeModel() -> TestViewModel<TestSendState, TestSendAction> {
        TestViewModel(
            initialDomainState: TestSendState(),
            interactor: TestSendInteractor()
        )
    }
}
}
