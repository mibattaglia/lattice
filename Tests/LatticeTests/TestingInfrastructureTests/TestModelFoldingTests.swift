import Foundation
import Testing

@testable import Lattice

/// `expect`, and how `send`, `receive` and `expect` fold the commits pending around them into one
/// assertion.
@Suite
struct TestModelFoldingTests {
    /// Two modifications after a suspension: pending (outside `state`) until one `expect`
    /// describes both.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func expectFoldsEveryPendingModificationIntoOneAssertion() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.fetch)?.value
            #expect(await model.state == LoadState())

            await model.expect {
                $0.count = 5
                $0.note = "x"
            }

            #expect(await model.state == LoadState(count: 5, note: "x"))
            await model.finish()
        }

        #expect(issues == [])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func expectThatLeavesOutAModificationFailsWithItsDiff() async {
        var expectLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.fetch)?.value
            expectLine = #line + 1
            await model.expect { $0.count = 5 }
            await model.finish()
        }

        #expect(issues.map(\.line) == [expectLine])
        #expect(issues.map(\.heading) == ["A state change does not match expectation."])
        #expect(issues.first?.message.contains(#"note: "x""#) == true)
    }

    /// With nothing pending, `expect` asserts the current state: a description of no change passes,
    /// a wrong one fails.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func expectWithNothingPendingAssertsTheLiveState() async {
        var wrongLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.increment) { $0.count = 1 }
            await model.expect { _ in }
            wrongLine = #line + 1
            await model.expect { $0.count = 99 }
            await model.finish()
        }

        #expect(issues.map(\.line) == [wrongLine])
        #expect(issues.map(\.heading) == ["A state change does not match expectation."])
    }

    /// A pending action needs `receive`: `expect` reports it first (and consumes it), then asserts.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func expectReportsAPendingActionFirst() async {
        var expectLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.load) { $0.count = 1 }
            expectLine = #line + 1
            await model.expect { _ in }
            #expect(await model.state.count == 42)
            await model.finish()
        }

        #expect(issues.map(\.line) == [expectLine])
        #expect(issues.map(\.heading) == ["Must handle 1 received action before 'expect'."])
        #expect(
            issues.first?.message.contains(
                "'expect' asserts modifications; assert the actions effects sent with 'receive'."
            ) == true
        )
    }

    /// §6: a modification an effect's preamble makes is committed inside `send`, so the send's
    /// assertion describes it with the action's change.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func preambleModificationsAreFoldedIntoSend() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.preamble) {
                $0.note = "go"
                $0.count = 10
            }
            await model.finish()
        }
        #expect(issues == [])

        var sendLine = 0
        let missing = await reportedIssueDetails {
            let model = await makeLoadModel()
            sendLine = #line + 1
            await model.send(.preamble) { $0.note = "go" }
            await model.finish()
        }
        #expect(missing.map(\.line) == [sendLine])
        #expect(missing.map(\.heading) == ["A state change does not match expectation."])
    }

    /// The modifications pending before the received action and those committed right after it are
    /// folded into the `receive`'s assertion.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func modificationsAroundTheReceivedActionAreFoldedIntoReceive() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.surround)
            await model.receive(.loaded(41)) {
                $0.isLoading = true  // modified before the action
                $0.count = 41  // the action
                $0.note = "done"  // modified right after it
            }
            await model.finish()
        }
        #expect(issues == [])

        var receiveLine = 0
        let missing = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.surround)
            receiveLine = #line + 1
            await model.receive(.loaded(41)) { $0.count = 41 }
            await model.finish()
        }
        #expect(missing.map(\.line) == [receiveLine])
        #expect(missing.map(\.heading) == ["A state change does not match expectation."])
    }

    /// `send` folds only the modifications its effects made before the first action they sent; the
    /// modification after that action is folded into the action's `receive`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func interleavedCommitsFoldOnlyTheLeadingModifications() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.interleave) { $0.note = "a" }
            await model.receive(.loaded(1)) {
                $0.count = 1
                $0.isLoading = true
            }
            await model.finish()
        }

        #expect(issues == [])
    }

    /// `expect` folds the modifications up to the next action; that action, and what follows it,
    /// stay pending for `receive`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func expectStopsAtTheNextActionWhichStaysPendingForReceive() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.modifyTwiceThenSend)?.value
            await model.expect {
                $0.count = 7
                $0.note = "seven"
            }
            await model.receive(.step(7)) { $0.values = [7] }
            await model.finish()
        }

        #expect(issues == [])
    }
}
