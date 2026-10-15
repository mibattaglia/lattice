import Foundation
import Testing

/// Runs `operation` and returns the message of every issue reported while it runs, in order,
/// recording each one as a known issue.
///
/// Assert the exact list: a missing report and an unexpected one both fail the test. An effect
/// inherits the known-issue context when it is created, so start and await every effect whose
/// reports are expected inside `operation`; an effect created before it reports an ordinary
/// failure.
@MainActor
func reportedIssues(_ operation: @MainActor () async -> Void) async -> [String] {
    let messages = IssueMessages()
    await withKnownIssue(isIntermittent: true) {
        await operation()
    } matching: { issue in
        messages.append(issue.comments.map(\.rawValue).joined(separator: "\n"))
        return true
    }
    return messages.values
}

private final class IssueMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ message: String) {
        lock.withLock { storage.append(message) }
    }
}
