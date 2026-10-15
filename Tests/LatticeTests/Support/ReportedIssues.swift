import Foundation
import Testing

/// Runs `operation` and returns the message of every issue reported while it runs, in order,
/// recording each one as a known issue.
///
/// The known-issue scope is intermittent, so it never fails a test by itself: assert the exact list
/// (`#expect(issues == [...])`), which is what fails on a missing report and on an unexpected one.
/// An effect inherits the known-issue context when it is created, so start and await every effect
/// whose reports are expected inside `operation`; an effect created before it reports an ordinary
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

/// An issue reported while ``reportedIssueDetails(isolation:_:)`` ran.
struct ReportedIssue: Equatable, CustomStringConvertible {
    let message: String
    /// `true` for an issue reported with `.warning` severity.
    let isWarning: Bool
    let fileID: String?
    let line: Int?

    /// The first line of `message`: the heading of a multi-line test failure.
    var heading: String {
        String(message.prefix { $0 != "\n" })
    }

    var description: String {
        "\(isWarning ? "warning" : "error") at \(fileID ?? "?"):\(line.map(String.init) ?? "?"): \(message)"
    }
}

extension ReportedIssue {
    init(_ issue: Issue) {
        self.init(
            message: issue.comments.map(\.rawValue).joined(separator: "\n"),
            isWarning: issue.severity == .warning,
            fileID: issue.sourceLocation?.fileID,
            line: issue.sourceLocation?.line
        )
    }
}

/// Like ``reportedIssues(_:)``, but runs `operation` on the caller's isolation, so the nonisolated
/// suites of `TestModel` tests can use it as well as `@MainActor` ones, and returns each issue with
/// its severity and location.
///
/// It collects the issues recorded through `Issue.record`, which is how IssueReporting's
/// `reportIssue` reaches Swift Testing; a failing `#expect` inside `operation` fails the test as
/// usual. `withKnownIssue` sees issues of every severity, so the warnings that
/// `Exhaustivity.off(showSkippedAssertions: true)` reports are in the list, marked `isWarning`.
/// The same rules apply: assert the exact list, and start and await inside `operation` every effect
/// whose reports are expected.
func reportedIssueDetails(
    isolation: isolated (any Actor)? = #isolation,
    _ operation: () async -> Void
) async -> [ReportedIssue] {
    let issues = ReportedIssueLog()
    await withKnownIssue(isIntermittent: true, isolation: isolation) {
        await operation()
    } matching: { issue in
        guard case .unconditional = issue.kind else { return false }
        issues.append(ReportedIssue(issue))
        return true
    }
    return issues.values
}

private final class IssueMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ message: String) {
        lock.withLock { storage.append(message) }
    }
}

private final class ReportedIssueLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ReportedIssue] = []

    var values: [ReportedIssue] { lock.withLock { storage } }

    func append(_ issue: ReportedIssue) {
        lock.withLock { storage.append(issue) }
    }
}
