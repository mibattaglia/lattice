#if canImport(IssueReporting)
    import IssueReporting
#endif

struct TestIssueLocation: Sendable {
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt
}

@inline(__always)
func reportIssueHelper(
    _ message: @autoclosure () -> String,
    at location: TestIssueLocation
) {
    #if canImport(IssueReporting)
        reportIssue(
            message(),
            fileID: location.fileID,
            filePath: location.filePath,
            line: location.line,
            column: location.column
        )
    #else
        _ = location.fileID
        _ = location.column
        assertionFailure(
            message(),
            file: location.filePath,
            line: location.line
        )
    #endif
}

@inline(__always)
func reportIssueHelper(
    _ error: any Error,
    message: String? = nil,
    at location: TestIssueLocation
) {
    #if canImport(IssueReporting)
        if let message {
            reportIssue(
                error,
                message,
                fileID: location.fileID,
                filePath: location.filePath,
                line: location.line,
                column: location.column
            )
        } else {
            reportIssue(
                error,
                fileID: location.fileID,
                filePath: location.filePath,
                line: location.line,
                column: location.column
            )
        }
    #else
        _ = location.fileID
        _ = location.column
        assertionFailure(
            message.map { "\(String(describing: error)): \($0)" } ?? String(describing: error),
            file: location.filePath,
            line: location.line
        )
    #endif
}

@inline(__always)
func reportTestFailure(
    _ failure: TestFailure,
    at location: TestIssueLocation
) {
    reportIssueHelper(
        failure.message,
        at: location
    )
}

@inline(__always)
func reportUnexpectedTestError(
    _ error: any Error,
    at location: TestIssueLocation
) {
    reportIssueHelper(
        error,
        message: "Unexpected test assertion failure.",
        at: location
    )
}

@MainActor
func withReportedTestFailures(
    at location: TestIssueLocation,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
    } catch let failure as TestFailure {
        reportTestFailure(
            failure,
            at: location
        )
    } catch {
        reportUnexpectedTestError(
            error,
            at: location
        )
    }
}
