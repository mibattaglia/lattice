import Foundation
import Testing

@testable import Lattice

/// Not `Equatable`, so its feature has no state equality unless one is passed.
@FeatureState
private struct UncomparableTestState: Sendable {
    var count = 0
    var note = ""
}

@FeatureState
private struct ComparableTestState: Equatable, Sendable {
    var count = 0
    var note = ""
}

private enum EqualityTestAction: Equatable, Sendable {
    case increment
    case annotate(String)
}

@Interactor<UncomparableTestState, EqualityTestAction>
private struct UncomparableTestInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment: state.count += 1
            case .annotate(let note): state.note = note
            }
            return .none
        }
    }
}

@Interactor<ComparableTestState, EqualityTestAction>
private struct ComparableTestInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment: state.count += 1
            case .annotate(let note): state.note = note
            }
            return .none
        }
    }
}

private final class IssueLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Int] = []

    var values: [Int] { lock.withLock { lines } }

    func append(_ line: Int?) {
        lock.withLock { lines.append(line ?? -1) }
    }
}

private let missingEqualityMessage = "TestViewModel cannot compare"

@Suite
@MainActor
struct TestViewModelStateEqualityTests {
    @Test
    func missingStateEqualityIsReportedAtInit() async {
        let feature = Feature(interactor: UncomparableTestInteractor())
        #expect(feature.areStatesEqual == nil)

        let initLine = #line + 2
        await expectIssue(containing: missingEqualityMessage, line: initLine) {
            _ = TestViewModel(initialState: UncomparableTestState(), feature: feature)
        }
    }

    @Test
    func stateAssertionsFailWithMissingStateEquality() async {
        let feature = Feature(interactor: UncomparableTestInteractor())
        let reportedLines = IssueLines()
        let initLine = #line + 3
        let sendLine = #line + 3
        await withKnownIssue(isolation: #isolation) {
            let model = TestViewModel(initialState: UncomparableTestState(), feature: feature)
            _ = await model.send(.increment) { $0.count = 1 }
        } matching: { issue in
            guard issue.description.contains(missingEqualityMessage) else { return false }
            reportedLines.append(issue.sourceLocation?.line)
            return true
        }

        #expect(reportedLines.values == [initLine, sendLine])
    }

    @Test
    func explicitStateEqualityCoversANonEquatableState() async {
        let model = TestViewModel(
            initialState: UncomparableTestState(),
            feature: Feature(interactor: UncomparableTestInteractor()),
            areStatesEqual: { $0.count == $1.count }
        )

        _ = await model.send(.increment) { $0.count = 1 }
        _ = await model.send(.annotate("ignored"))  // `note` is outside the comparison

        #expect(model.state.count == 1)
        #expect(model.state.note == "ignored")
    }

    @Test
    func featureStateEqualityTakesPrecedenceOverTheExplicitOne() async {
        let model = TestViewModel(
            initialState: ComparableTestState(),
            feature: Feature(interactor: ComparableTestInteractor()),
            areStatesEqual: { _, _ in true }  // would accept any assertion
        )

        let sendLine = #line + 1
        await expectIssue(containing: "A state change does not match expectation.", line: sendLine) { _ = await model.send(.increment) { $0.count = 2 } }
    }

    @Test
    func customFeatureStateEqualityDrivesAssertions() async {
        let model = TestViewModel(
            initialState: ComparableTestState(),
            feature: Feature(
                interactor: ComparableTestInteractor(),
                areStatesEqual: { $0.count == $1.count }
            )
        )

        _ = await model.send(.annotate("ignored"))  // `note` is outside the comparison
        _ = await model.send(.increment) { $0.count = 1 }

        #expect(model.state == ComparableTestState(count: 1, note: "ignored"))
    }
}
