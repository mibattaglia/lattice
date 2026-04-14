import Foundation

/// Error thrown by ``TestViewModel`` and ``TestEventTask`` when a test assertion fails.
public struct TestFailure: Error, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

extension TestFailure {
    static func mustHandleReceivedActionsBeforeSending<Action>(
        _ actions: some Sequence<Action>
    ) -> Self {
        Self(
            """
            Must handle received actions before sending another action.

            Unhandled actions: \(describe(Array(actions)))
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
                There are effects in flight. If this action depends on time, make sure the clock \
                has advanced far enough for the effect to complete.
                """
        } else {
            suggestion =
                """
                There are no in-flight effects that could deliver this action. The expected \
                effect may have already completed or been cancelled.
                """
        }

        return Self(
            """
            Expected to receive \(expectedActionDescription), but none arrived\(timing).

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
            Expected effects to finish, but \(count) effect\(count == 1 ? "" : "s") \
            remained in flight\(timing).
            """
        )
    }

    static func expectedTaskToFinish(timeout: Duration?) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""
        return Self("Expected task to finish, but it remained in flight\(timing).")
    }

    static func stateMutationDidNotMatchExpectation<State>(
        operation: String,
        expected: State,
        actual: State
    ) -> Self {
        Self(
            """
            State mutation did not match expectation while processing \(operation).

            Expected: \(describe(expected))
            Actual: \(describe(actual))
            """
        )
    }

    static func assertionClosureMadeNoChanges<State>(
        operation: String,
        state: State
    ) -> Self {
        Self(
            """
            Assertion closure made no changes while processing \(operation), but the feature \
            mutated state to:

            \(describe(state))
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
        Self(
            """
            Received unexpected action\(Array(actions).count == 1 ? "" : "s") left unhandled.

            Unhandled actions: \(describe(Array(actions)))
            """
        )
    }

    static func noReceivedActionsToSkip() -> Self {
        Self("There were no received actions to skip.")
    }

    static func noInFlightEffectsToSkip() -> Self {
        Self("There were no in-flight effects to skip.")
    }
}

private func describe<T>(_ value: T) -> String {
    String(reflecting: value)
}
