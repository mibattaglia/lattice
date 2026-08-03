/// Reports a non-fatal runtime misuse.
///
/// Routes through swift-issue-reporting when available (SwiftPM builds, tests) so misuse
/// surfaces as test failures and purple runtime warnings; falls back to `assertionFailure`
/// in DEBUG for integrations without the dependency (e.g. CocoaPods).
func latticeReportIssue(
    _ message: @autoclosure () -> String,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) {
    #if canImport(IssueReporting)
        reportIssue(message(), fileID: fileID, filePath: filePath, line: line, column: column)
    #else
        #if DEBUG
            assertionFailure("\(message()) (\(fileID):\(line))")
        #endif
    #endif
}

#if canImport(IssueReporting)
    import IssueReporting
#endif
