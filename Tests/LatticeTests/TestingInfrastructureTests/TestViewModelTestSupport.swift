import Observation
import Testing

@testable import Lattice

@ObservableState
struct TestSupportViewState: Equatable, Sendable {}

typealias TestSupportFeature<Action, DomainState> = Feature<Action, DomainState, TestSupportViewState>

@MainActor
func makeTestViewModel<I: Interactor & Sendable>(
    initialDomainState: I.DomainState,
    interactor: I
) -> TestViewModel<TestSupportFeature<I.Action, I.DomainState>>
where I.DomainState: Equatable {
    TestViewModel<TestSupportFeature<I.Action, I.DomainState>>(
        initialDomainState: initialDomainState,
        interactor: interactor.eraseToAnyInteractor(),
        areStatesEqual: { $0 == $1 }
    )
}

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
