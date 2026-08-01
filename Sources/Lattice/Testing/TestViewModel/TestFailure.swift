import Foundation

#if canImport(CustomDump)
    import CustomDump
#endif

/// Internal diagnostic built by ``TestViewModel`` and ``TestEventTask`` when a test assertion
/// fails.
struct TestFailure: Error, CustomStringConvertible, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        message
    }
}

extension TestFailure {
    static func mustAssertCommitsBeforeSending<DomainState, Action>(
        _ commits: some Sequence<PendingCommit<DomainState, Action>>
    ) -> Self {
        let commits = Array(commits)
        return Self(
            """
            Must assert \(commits.count) pending commit\(commits.count == 1 ? "" : "s") before \
            sending another action.

            Pending commits:
            \(describeCommits(commits))
            """
        )
    }

    static func sendAfterDismount<Action>(_ action: Action) -> Self {
        Self(
            """
            Can't send an action to a dismounted TestViewModel.

            Action: \(describe(action))
            """
        )
    }

    static func expectedCommit(timeout: Duration?) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""
        return Self(
            """
            Expected an effect to commit a state mutation, but none arrived\(timing).

            If the effect depends on time, make sure the clock has advanced far enough for it \
            to reach its 'modify'.
            """
        )
    }

    static func expectedMutationButReceivedAction<Action>(_ action: Action) -> Self {
        Self(
            """
            Expected the next commit to be a state mutation (effectState.modify), but received \
            an action re-entry (effectState.send):

            \(describe(action).indent(by: 2))

            Assert it with 'receive' instead.
            """
        )
    }

    static func expectedActionButReceivedMutation(
        expected expectedActionDescription: String
    ) -> Self {
        Self(
            """
            Expected to receive \(expectedActionDescription), but the next commit was a state \
            mutation (effectState.modify).

            Assert it with 'expect' instead.
            """
        )
    }

    static func unexpectedReceivedAction<Action>(
        _ action: Action,
        expected expectedActionDescription: String
    ) -> Self {
        Self(
            """
            Received unexpected action:

            Expected: \(expectedActionDescription)
            Received: \(describe(action))
            """
        )
    }

    static func unexpectedReceivedAction<Action>(
        _ action: Action,
        expected expectedAction: Action
    ) -> Self {
        Self(
            """
            Received unexpected action:

            \(diffMessage(
                expected: expectedAction,
                actual: action,
                actualLabel: "Received"
            ))
            """
        )
    }

    static func expectedToReceiveAction(
        _ expectedActionDescription: String,
        timeout: Duration?
    ) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""
        return Self(
            """
            Expected to receive \(expectedActionDescription), but none arrived\(timing).

            If the re-entry depends on time, make sure the clock has advanced far enough for \
            the effect to reach its 'send'.
            """
        )
    }

    static func effectsDidNotFinish(timeout: Duration?) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""
        return Self(
            "Expected effects to finish, but in-flight effects remained\(timing)."
        )
    }

    static func expectedTaskToFinish(timeout: Duration?) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""
        return Self("Expected task to finish, but it remained in flight\(timing).")
    }

    static func stateMutationDidNotMatchExpectation<State>(
        expected: State,
        actual: State,
        didExpectStateChange: Bool
    ) -> Self {
        let heading = didExpectStateChange
            ? "A state change does not match expectation."
            : "State was not expected to change, but a change occurred."
        return Self(
            """
            \(heading)

            \(diffMessage(expected: expected, actual: actual, actualLabel: "Actual"))
            """
        )
    }

    static func assertionThrew(
        operation: String,
        error: any Error
    ) -> Self {
        Self("State assertion for \(operation) threw error: \(error)")
    }

    static func unassertedCommits<DomainState, Action>(
        _ commits: some Sequence<PendingCommit<DomainState, Action>>
    ) -> Self {
        let commits = Array(commits)
        return Self(
            """
            \(commits.count) pending commit\(commits.count == 1 ? "" : "s") left unasserted.

            Pending commits:
            \(describeCommits(commits))
            """
        )
    }

    static func unassertedCommitsAtDeinit<DomainState, Action>(
        _ commits: some Sequence<PendingCommit<DomainState, Action>>
    ) -> Self {
        let commits = Array(commits)
        return Self(
            """
            TestViewModel deinitialized with \(commits.count) pending \
            commit\(commits.count == 1 ? "" : "s") left unasserted.

            Pending commits:
            \(describeCommits(commits))

            Assert each commit with 'expect'/'receive', consume them with \
            'skipPendingCommits()', or set 'exhaustivity = .off'.
            """
        )
    }

    static func noPendingCommitsToSkip() -> Self {
        Self("There were no pending commits to skip.")
    }
}

private func describe<T>(_ value: T) -> String {
    #if canImport(CustomDump)
        String(customDumping: value)
    #else
        String(reflecting: value)
    #endif
}

private func describeCommits<DomainState, Action>(
    _ commits: [PendingCommit<DomainState, Action>]
) -> String {
    commits
        .map { commit in
            switch commit {
            case .mutation:
                return "  - state mutation (effectState.modify)"
            case .action(let action, _):
                return "  - action re-entry (effectState.send): \(describe(action))"
            }
        }
        .joined(separator: "\n")
}

private func diffMessage<T>(
    expected: T,
    actual: T,
    actualLabel: String
) -> String {
    #if canImport(CustomDump)
        if let difference = diff(expected, actual, format: .proportional) {
            return "\(difference.indent(by: 4))\n\n(Expected: −, \(actualLabel): +)"
        }
    #endif

    return """
        Expected:
        \(describe(expected).indent(by: 2))

        \(actualLabel):
        \(describe(actual).indent(by: 2))
        """
}

extension String {
    fileprivate func indent(by indent: Int) -> String {
        let indentation = String(repeating: " ", count: indent)
        return indentation + self.replacingOccurrences(of: "\n", with: "\n\(indentation)")
    }
}
