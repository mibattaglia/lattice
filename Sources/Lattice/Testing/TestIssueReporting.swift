import IssueReporting

/// Where a test shell reports an issue: the test line that called it, or, for what is reported at
/// deinit, the line that created the test model.
struct TestIssueLocation: Sendable {
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt
}

/// Reports `failure` at `location`.
///
/// Synchronous and nonisolated: it runs on the isolation of the shell that calls it, in the test's
/// task, so Swift Testing attributes the issue to the test (and `withKnownIssue` sees it) under the
/// main-actor ``TestViewModel`` and the actor ``TestModel`` alike. A shell's `isolated deinit` is the
/// exception: it runs without the test's task-locals, so an issue reported there is unattributed.
func reportTestFailure(
    _ failure: TestFailure,
    severity: IssueSeverity = .error,
    at location: TestIssueLocation
) {
    reportIssue(
        failure.message,
        severity: severity,
        fileID: location.fileID,
        filePath: location.filePath,
        line: location.line,
        column: location.column
    )
}
