import Foundation
import Testing

@testable import Lattice

/// Exhaustive mode reports every commit no assertion described, consumes it and lets the test go on;
/// `.off` skips it, reporting each skip as a warning when `showSkippedAssertions`.
@Suite
struct TestModelExhaustivityTests {
    /// The two actions `.startSequence`'s effect sent are reported at the next `send`, which then
    /// runs from the state after them.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func actionsLeftPendingAreReportedAtTheNextSendWhichStillRuns() async {
        var sendLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.startSequence)
            sendLine = #line + 1
            await model.send(.increment) { $0.count = 1 }
            #expect(await model.state == LoadState(count: 1, values: [1, 2]))
            await model.finish()
        }

        #expect(issues.map(\.line) == [sendLine])
        #expect(issues.map(\.isWarning) == [false])
        #expect(
            issues.map(\.message) == [
                """
                Must handle 2 received actions before sending another action.

                Unhandled actions: [
                  [0]: .step(1),
                  [1]: .step(2)
                ]
                """
            ]
        )
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func modificationsLeftPendingAreReportedAtTheNextSendWithTheirDiffs() async {
        var sendLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.fetch)?.value
            sendLine = #line + 1
            await model.send(.increment) { $0.count = 6 }
            await model.finish()
        }

        #expect(issues.map(\.line) == [sendLine])
        #expect(issues.map(\.isWarning) == [false])
        #expect(issues.map(\.heading) == ["Must handle 2 modifications before sending another action."])
        #expect(issues.first?.message.contains("(Before: −, After: +)") == true)
        #expect(issues.first?.message.contains("Assert the modifications effects made with 'expect'.") == true)
    }

    /// Port of the old `finishReportsUnhandledReceivedActionsAtCaller`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func finishReportsTheActionsLeftPending() async {
        var finishLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.startSequence)
            finishLine = #line + 1
            await model.finish()
            #expect(await model.state.values == [1, 2])
        }

        #expect(issues.map(\.line) == [finishLine])
        #expect(issues.map(\.isWarning) == [false])
        #expect(issues.map(\.heading) == ["Received 2 unexpected actions left unhandled."])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func finishReportsTheActionsAndModificationsLeftPending() async {
        var finishLines: [Int] = []
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.fetch)?.value
            finishLines.append(#line + 1)
            await model.finish()

            await model.send(.surround)
            finishLines.append(#line + 1)
            await model.finish()
        }

        #expect(issues.map(\.line) == finishLines)
        #expect(issues.map(\.isWarning) == [false, false])
        #expect(
            issues.map(\.heading) == [
                "Received 2 unasserted modifications left unhandled.",
                "Received 1 unexpected action and 2 unasserted modifications left unhandled.",
            ]
        )
    }

    /// A modification that leaves the state equal to what it was needs no assertion: not at the
    /// next `send`, not at `expect`, not at `finish`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func modificationThatChangesNothingNeedsNoAssertion() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.noop)?.value
            await model.send(.noop)?.value
            await model.send(.noop)?.value
            await model.expect { _ in }
            await model.send(.noop)?.value
            await model.finish()
        }

        #expect(issues == [])
    }

    /// `.off(showSkippedAssertions: false)` skips what no assertion described, silently, before
    /// `send`, `receive`, `expect` and `finish`; each assertion compares against the state skipped
    /// to.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func offSkipsWhatNoAssertionDescribedSilently() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel(exhaustivity: .off(showSkippedAssertions: false))
            await model.send(.startSequence)
            await model.receive(.step(2)) { $0.values = [1, 2] }  // `.step(1)` skipped: from [1]
            await model.send(.fetch)?.value
            await model.send(.increment) { $0.count = 6 }  // the two modifications skipped: from 5
            await model.send(.load) { $0.count = 7 }
            await model.expect { _ in }  // `.loaded(41)` skipped
            #expect(await model.state.count == 48)
            await model.send(.surround)
            await model.finish()  // `.loaded(41)` and the two modifications skipped
            #expect(await model.state == LoadState(count: 89, isLoading: true, note: "done", values: [1, 2]))
        }

        #expect(issues == [])
    }

    /// `.off(showSkippedAssertions: true)`: the same skips, each reported as a warning at the call
    /// that skipped.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func offWithShownSkippedAssertionsReportsEachSkipAsAWarning() async {
        var lines: [Int] = []
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel(exhaustivity: .off(showSkippedAssertions: true))
            await model.send(.startSequence)
            lines.append(#line + 1)
            await model.receive(.step(2)) { $0.values = [1, 2] }
            await model.send(.fetch)?.value
            lines.append(#line + 1)
            await model.send(.increment) { $0.count = 6 }
            await model.send(.load) { $0.count = 7 }
            lines.append(#line + 1)
            await model.expect { _ in }
            await model.send(.surround)
            lines.append(#line + 1)
            await model.finish()
        }

        #expect(
            issues.map(\.heading) == [
                "Skipped 1 received action before receiving LoadAction.step(2).",
                "Skipped 2 modifications before sending another action.",
                "Skipped 1 received action before 'expect'.",
                "Skipped 1 received action and 2 modifications at finish.",
            ]
        )
        #expect(issues.map(\.isWarning) == [true, true, true, true])
        #expect(issues.map(\.line) == lines)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func setExhaustivitySwitchesTheModeMidTest() async {
        var sendLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.setExhaustivity(.off(showSkippedAssertions: false))
            await model.send(.startSequence)
            await model.send(.increment) { $0.count = 1 }  // skipped silently
            await model.send(.startSequence)
            await model.setExhaustivity(.on)
            sendLine = #line + 1
            await model.send(.increment) { $0.count = 2 }  // exhaustive again: reported
            await model.finish()
        }

        #expect(issues.map(\.line) == [sendLine])
        #expect(issues.map(\.isWarning) == [false])
        #expect(issues.map(\.heading) == ["Must handle 2 received actions before sending another action."])
    }

    /// `skipReceived` advances the asserted state past every pending action and modification;
    /// with nothing pending, the strict form reports it.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func skipReceivedAdvancesPastEveryPendingActionAndModification() async {
        var strictSkipLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.startSequence)
            await model.skipReceived()
            #expect(await model.state.values == [1, 2])

            await model.send(.fetch)?.value
            await model.skipReceived()
            #expect(await model.state == LoadState(count: 5, note: "x", values: [1, 2]))

            strictSkipLine = #line + 1
            await model.skipReceived()
            await model.skipReceived(strict: false)
            await model.finish()
        }

        #expect(issues.map(\.line) == [strictSkipLine])
        #expect(issues.map(\.message) == ["There were no received actions or modifications to skip."])
    }
}
