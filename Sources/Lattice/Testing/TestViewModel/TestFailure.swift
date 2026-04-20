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
    static func mustHandleReceivedActionsBeforeSending<Action>(
        _ actions: some Sequence<Action>
    ) -> Self {
        let actions = Array(actions)
        return Self(
            """
            Must handle \(actions.count) received action\(actions.count == 1 ? "" : "s") before \
            sending another action.

            Unhandled actions: \(describeActions(actions))
            """
        )
    }

    static func unexpectedReceivedAction<Action>(
        _ action: Action,
        expected expectedActionDescription: String,
        receivedActionLater: Bool
    ) -> Self {
        Self(
            """
            Received unexpected action\(receivedActionLater ? " before this one" : ""):

            Expected: \(expectedActionDescription)
            Received: \(describe(action))
            """
        )
    }

    static func unexpectedReceivedAction<Action>(
        _ action: Action,
        expected expectedAction: Action,
        receivedActionLater: Bool
    ) -> Self {
        let qualifier = receivedActionLater ? " before this one" : ""
        return Self(
            """
            Received unexpected action\(qualifier):

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
        timeout: Duration?,
        hasInFlightEffects: Bool
    ) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""
        let suggestion: String

        if hasInFlightEffects {
            suggestion =
                """
                There are emissions in flight. If this action depends on time, make sure the clock \
                has advanced far enough for the emission to complete.
                """
        } else {
            suggestion =
                """
                There are no in-flight emissions that could deliver this action. The expected \
                emission may have already completed or been cancelled.
                """
        }

        return Self(
            """
            Expected to receive \(expectedActionDescription), but none arrived\(timing).

            \(suggestion)
            """
        )
    }

    static func expectedToReceiveAction<Action>(
        _ expectedAction: Action,
        timeout: Duration?,
        hasInFlightEffects: Bool
    ) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""
        let suggestion: String

        if hasInFlightEffects {
            suggestion =
                """
                There are emissions in flight. If this action depends on time, make sure the clock \
                has advanced far enough for the emission to complete.
                """
        } else {
            suggestion =
                """
                There are no in-flight emissions that could deliver this action. The expected \
                emission may have already completed or been cancelled.
                """
        }

        return Self(
            """
            Expected to receive the following action, but didn't\(timing):

            \(describe(expectedAction).indent(by: 2))

            \(suggestion)
            """
        )
    }

    static func expectedEffectsToFinish(
        count: Int,
        timeout: Duration?
    ) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""

        return Self(
            """
            Expected emissions to finish, but \(count) emission\(count == 1 ? "" : "s") \
            remained in flight\(timing).
            """
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

    static func assertionClosureMadeNoChanges<State>(
        operation: String,
        state: State
    ) -> Self {
        Self(
            """
            Expected state to change, but no change occurred.

            The trailing closure made no observable modifications to state. If no change to state \
            is expected, omit the trailing closure.

            Actual state after \(operation):
            \(describe(state).indent(by: 2))
            """
        )
    }

    static func assertionThrew(
        operation: String,
        error: any Error
    ) -> Self {
        Self("State assertion for \(operation) threw error: \(error)")
    }

    static func unhandledReceivedActions<Action>(
        _ actions: some Sequence<Action>
    ) -> Self {
        let actions = Array(actions)
        return Self(
            """
            Received \(actions.count) unexpected action\(actions.count == 1 ? "" : "s") left \
            unhandled.

            Unhandled actions: \(describeActions(actions))
            """
        )
    }

    static func noReceivedActionsToSkip() -> Self {
        Self("There were no received actions to skip.")
    }

    static func noInFlightEffectsToSkip() -> Self {
        Self("There were no in-flight emissions to skip.")
    }
}

private func describe<T>(_ value: T) -> String {
    #if canImport(CustomDump)
        String(customDumping: value)
    #else
        String(reflecting: value)
    #endif
}

private func describeActions<Action>(_ actions: [Action]) -> String {
    describe(actions)
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

private extension String {
    func indent(by indent: Int) -> String {
        let indentation = String(repeating: " ", count: indent)
        return indentation + self.replacingOccurrences(of: "\n", with: "\n\(indentation)")
    }
}
