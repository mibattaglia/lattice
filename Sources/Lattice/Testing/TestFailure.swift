import Foundation

#if canImport(CustomDump)
    import CustomDump
#endif

/// Internal diagnostic the test shells (``TestModel``, ``TestViewModel``) report when a test
/// assertion fails.
struct TestFailure: Error, CustomStringConvertible, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        message
    }
}

/// Where a test shell deals with commits no assertion described: it reports them (exhaustive) or
/// skips them (`.off`).
enum PendingCheckpoint {
    case send
    /// Only skipped: an exhaustive `receive` reports each unexpected action on its own.
    case receive(String)
    /// Only the actions that precede the modifications `expect` folds.
    case expect
    case finish
    /// The test model's deinit, which reports at the line that created it.
    case deallocation
}

/// A modification an effect made, shown in a report as the change from `previous` to `resulting`.
struct ReportedModification<State> {
    let previous: State
    let resulting: State
}

extension TestFailure {
    /// Exhaustive: commits pending at `checkpoint` that no assertion described.
    static func unhandledCommits<State, Action>(
        actions: [Action],
        modifications: [ReportedModification<State>],
        at checkpoint: PendingCheckpoint
    ) -> Self {
        let pendingSummary = describeCounts(actions.count, "received action", modifications.count, "modification")
        let leftSummary = describeCounts(
            actions.count, "unexpected action", modifications.count, "unasserted modification"
        )
        let heading: String
        var footer: String?
        switch checkpoint {
        case .send:
            heading = "Must handle \(pendingSummary) before sending another action."
        case .receive(let expectedActionDescription):
            heading = "Must handle \(pendingSummary) before receiving \(expectedActionDescription)."
        case .expect:
            heading = "Must handle \(pendingSummary) before 'expect'."
            footer = "'expect' asserts modifications; assert the actions effects sent with 'receive'."
        case .finish:
            heading = "Received \(leftSummary) left unhandled."
        case .deallocation:
            heading = "Received \(leftSummary) left unhandled when the test model was deallocated."
            footer = """
                This report comes from the test model's deinit and cannot fail the test: end \
                exhaustive tests with 'finish()'.
                """
        }
        if footer == nil, !modifications.isEmpty {
            footer = "Assert the modifications effects made with 'expect'."
        }
        return Self(
            describeCommits(
                heading: heading,
                actionsLabel: "Unhandled actions",
                actions: actions,
                modificationsLabel: "Unasserted modifications",
                modifications: modifications,
                footer: footer
            )
        )
    }

    /// `.off(showSkippedAssertions: true)`: commits skipped at `checkpoint`, reported as a warning.
    static func skippedCommits<State, Action>(
        actions: [Action],
        modifications: [ReportedModification<State>],
        at checkpoint: PendingCheckpoint
    ) -> Self {
        let place: String
        switch checkpoint {
        case .send:
            place = "before sending another action"
        case .receive(let expectedActionDescription):
            place = "before receiving \(expectedActionDescription)"
        case .expect:
            place = "before 'expect'"
        case .finish:
            place = "at finish"
        case .deallocation:
            place = "when the test model was deallocated"
        }
        let summary = describeCounts(actions.count, "received action", modifications.count, "modification")
        return Self(
            describeCommits(
                heading: "Skipped \(summary) \(place).",
                actionsLabel: "Skipped actions",
                actions: actions,
                modificationsLabel: "Skipped modifications",
                modifications: modifications,
                footer: nil
            )
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
            Received: \(testDescription(of: action))
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

    /// `timeout` is `nil` when `receive` stopped waiting because no effect was left in flight.
    static func expectedToReceiveAction(
        _ expectedActionDescription: String,
        timeout: Duration?,
        hasInFlightEffects: Bool
    ) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""
        return Self(
            """
            Expected to receive \(expectedActionDescription), but none arrived\(timing).

            \(receiveSuggestion(hasInFlightEffects: hasInFlightEffects))
            """
        )
    }

    /// `timeout` is `nil` when `receive` stopped waiting because no effect was left in flight.
    static func expectedToReceiveAction<Action>(
        _ expectedAction: Action,
        timeout: Duration?,
        hasInFlightEffects: Bool
    ) -> Self {
        let timing = timeout.map { " after \($0)" } ?? ""
        return Self(
            """
            Expected to receive the following action, but didn't\(timing):

            \(testDescription(of: expectedAction).indent(by: 2))

            \(receiveSuggestion(hasInFlightEffects: hasInFlightEffects))
            """
        )
    }

    static func expectedEffectsToFinish(
        count: Int,
        timeout: Duration
    ) -> Self {
        Self(
            """
            Expected effects to finish, but \(count) effect\(count == 1 ? "" : "s") remained in \
            flight after \(timeout).
            """
        )
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

    static func noReceivedCommitsToSkip() -> Self {
        Self("There were no received actions or modifications to skip.")
    }

    static func noInFlightEffectsToSkip() -> Self {
        Self("There were no in-flight effects to skip.")
    }

    static func overlappingWait() -> Self {
        Self(
            """
            The test model is already waiting for its effects: 'receive', 'finish' and \
            'skipInFlightEffects' each wait, so await one before starting another.
            """
        )
    }

    static func missingStateEquality<State>(_ stateType: State.Type) -> Self {
        Self(
            """
            The test model cannot compare '\(State.self)' values: the feature has no state \
            equality.

            Make the state 'Equatable', build the feature with \
            'Feature(interactor:areStatesEqual:)', or create the test model with \
            'areStatesEqual:'.
            """
        )
    }
}

private func receiveSuggestion(hasInFlightEffects: Bool) -> String {
    if hasInFlightEffects {
        return """
            There are effects in flight. If this action depends on time, make sure the clock has \
            advanced far enough for the effect to send it.
            """
    }
    return """
        There are no in-flight effects that could send this action. The effect that sends it may \
        have already finished or been cancelled.
        """
}

/// "2 received actions and 1 modification"; a zero count is left out.
private func describeCounts(
    _ firstCount: Int,
    _ firstNoun: String,
    _ secondCount: Int,
    _ secondNoun: String
) -> String {
    [(firstCount, firstNoun), (secondCount, secondNoun)]
        .filter { $0.0 > 0 }
        .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        .joined(separator: " and ")
}

private func describeCommits<State, Action>(
    heading: String,
    actionsLabel: String,
    actions: [Action],
    modificationsLabel: String,
    modifications: [ReportedModification<State>],
    footer: String?
) -> String {
    var sections = [heading]
    if !actions.isEmpty {
        sections.append("\(actionsLabel): \(testDescription(of: actions))")
    }
    if !modifications.isEmpty {
        let diffs = modifications.map {
            diffMessage(expected: $0.previous, actual: $0.resulting, expectedLabel: "Before", actualLabel: "After")
        }
        sections.append("\(modificationsLabel):\n\n\(diffs.joined(separator: "\n\n"))")
    }
    if let footer {
        sections.append(footer)
    }
    return sections.joined(separator: "\n\n")
}

/// How the test shells render a value in a failure message.
func testDescription<T>(of value: T) -> String {
    #if canImport(CustomDump)
        String(customDumping: value)
    #else
        String(reflecting: value)
    #endif
}

private func diffMessage<T>(
    expected: T,
    actual: T,
    expectedLabel: String = "Expected",
    actualLabel: String
) -> String {
    #if canImport(CustomDump)
        if let difference = diff(expected, actual, format: .proportional) {
            return "\(difference.indent(by: 4))\n\n(\(expectedLabel): −, \(actualLabel): +)"
        }
    #endif

    return """
        \(expectedLabel):
        \(testDescription(of: expected).indent(by: 2))

        \(actualLabel):
        \(testDescription(of: actual).indent(by: 2))
        """
}

private extension String {
    func indent(by indent: Int) -> String {
        let indentation = String(repeating: " ", count: indent)
        return indentation + self.replacingOccurrences(of: "\n", with: "\n\(indentation)")
    }
}
