import CasePaths
import Foundation
import Testing

@testable import Lattice

// Not `@MainActor`: test model suites run off the main actor. `@available` is on each `@Test`.
@Suite
struct TestModelSendTests {
    /// `send` asserts the root transition; the action its effect sent is pending, outside `state`,
    /// until `receive` asserts it.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func receiveMatchesAnEquatableAction() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()

            let task = await model.send(.load) { $0.count = 1 }

            #expect(task != nil)
            #expect(await model.state.count == 1)

            await model.receive(.loaded(41)) { $0.count = 42 }

            #expect(await model.state.count == 42)
            await model.finish()
        }

        #expect(issues == [])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func receiveMatchesAPredicate() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.load) { $0.count = 1 }

            await model.receive({
                if case .loaded = $0 { return true }
                return false
            }) {
                $0.count = 42
            }

            #expect(await model.state.count == 42)
            await model.finish()
        }

        #expect(issues == [])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func receiveMatchesACasePath() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.load) { $0.count = 1 }

            await model.receive(\.loaded) { $0.count = 42 }

            #expect(await model.state.count == 42)
            await model.finish()
        }

        #expect(issues == [])
    }

    /// Reported at the caller's line, through the test's own task: Swift Testing attributes it to
    /// this test and this file.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func sendMismatchReportsTheStateDiffAtTheCaller() async {
        var sendLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            sendLine = #line + 1
            await model.send(.load) { $0.count = 999 }
            await model.skipReceived()
        }

        #expect(issues.map(\.line) == [sendLine])
        #expect(issues.map(\.fileID) == ["LatticeTests/TestModelSendTests.swift"])
        #expect(issues.map(\.isWarning) == [false])
        #expect(issues.map(\.heading) == ["A state change does not match expectation."])
        #expect(issues.first?.message.contains("count: 999") == true)
        #expect(issues.first?.message.contains("count: 1") == true)
        #expect(issues.first?.message.contains("(Expected: −, Actual: +)") == true)
    }

    /// A failed `receive` reports the first pending action, diffed against the expected one, and
    /// consumes everything pending: the `finish` after it has nothing left to report.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func receiveMismatchReportsTheActionDiffAtTheCallerAndConsumesWhatWasPending() async {
        var receiveLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.load) { $0.count = 1 }
            receiveLine = #line + 1
            await model.receive(.increment)
            #expect(await model.state.count == 42)
            await model.finish()
        }

        #expect(issues.map(\.line) == [receiveLine])
        #expect(issues.map(\.heading) == ["Received unexpected action:"])
        #expect(issues.first?.message.contains("increment") == true)
        #expect(issues.first?.message.contains("loaded(41)") == true)
        #expect(issues.first?.message.contains("(Expected: −, Received: +)") == true)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func sendWithoutAnAssertionExpectsNoChange() async {
        var sendLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            sendLine = #line + 1
            await model.send(.increment)
            await model.finish()
        }

        #expect(issues.map(\.line) == [sendLine])
        #expect(issues.map(\.heading) == ["State was not expected to change, but a change occurred."])
    }
}
