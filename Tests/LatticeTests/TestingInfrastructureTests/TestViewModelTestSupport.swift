import Testing

@testable import Lattice

@MainActor
func expectIssue(
    fileID: StaticString = #fileID,
    line expectedLine: Int = #line,
    matching matches: @escaping @Sendable (Issue) -> Bool,
    _ operation: @escaping @MainActor () async -> Void
) async {
    await withKnownIssue(isolation: #isolation) {
        await operation()
    } matching: { issue in
        issue.sourceLocation?.fileID == "\(fileID)"
            && issue.sourceLocation?.line == expectedLine
            && matches(issue)
    }
}

@MainActor
func expectIssue(
    comment expectedComment: String,
    fileID: StaticString = #fileID,
    line expectedLine: Int = #line,
    _ operation: @escaping @MainActor () async -> Void
) async {
    await expectIssue(
        fileID: fileID,
        line: expectedLine,
        matching: { issue in
            issue.comments.contains { $0.rawValue == expectedComment }
        },
        operation
    )
}

@MainActor
func expectIssue(
    containing expectedMessage: String,
    fileID: StaticString = #fileID,
    line expectedLine: Int = #line,
    _ operation: @escaping @MainActor () async -> Void
) async {
    await expectIssue(
        fileID: fileID,
        line: expectedLine,
        matching: { $0.description.contains(expectedMessage) },
        operation
    )
}

/// Namespace suite: groups every testing-infrastructure suite under one prefix so the plan's
/// gate (`swift test --filter TestingInfrastructureTests`) selects exactly these.
enum TestingInfrastructureTests {}
