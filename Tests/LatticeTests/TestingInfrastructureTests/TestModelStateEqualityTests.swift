import Foundation
import Testing

@testable import Lattice

/// Not `Equatable`: its feature has no state equality unless one is passed.
@FeatureState
struct UncomparableTestState: Sendable {
    var count = 0
    var note = ""
}

@FeatureState
struct ComparableTestState: Equatable, Sendable {
    var count = 0
    var note = ""
}

enum EqualityTestAction: Equatable, Sendable {
    case increment
    case annotate(String)
}

@Interactor<UncomparableTestState, EqualityTestAction>
struct UncomparableTestInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
            case .annotate(let note):
                state.note = note
            }
        }
    }
}

@Interactor<ComparableTestState, EqualityTestAction>
struct ComparableTestInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
            case .annotate(let note):
                state.note = note
            }
        }
    }
}

let missingStateEqualityHeading =
    "The test model cannot compare 'UncomparableTestState' values: the feature has no state equality."

@Suite
struct TestModelStateEqualityTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func missingStateEqualityIsReportedAtInitAndAtEveryAssertion() async {
        var lines: [Int] = []
        let issues = await reportedIssueDetails {
            let feature = Feature(interactor: UncomparableTestInteractor())
            #expect(feature.areStatesEqual == nil)
            lines.append(#line + 1)
            let model = await TestModel(initialState: UncomparableTestState(), feature: feature)
            lines.append(#line + 1)
            await model.send(.increment) { $0.count = 1 }
            await model.finish()
        }

        #expect(issues.map(\.line) == lines)
        #expect(issues.map(\.heading) == [missingStateEqualityHeading, missingStateEqualityHeading])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func explicitStateEqualityCoversANonEquatableState() async {
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: UncomparableTestState(),
                feature: Feature(interactor: UncomparableTestInteractor()),
                areStatesEqual: { $0.count == $1.count }
            )
            await model.send(.increment) { $0.count = 1 }
            await model.send(.annotate("ignored"))  // `note` is outside the comparison
            let state = await model.state
            #expect(state.count == 1)
            #expect(state.note == "ignored")
            await model.finish()
        }

        #expect(issues == [])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func featureStateEqualityTakesPrecedenceOverTheExplicitOne() async {
        var sendLine = 0
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: ComparableTestState(),
                feature: Feature(interactor: ComparableTestInteractor()),
                areStatesEqual: { _, _ in true }  // would accept any assertion
            )
            sendLine = #line + 1
            await model.send(.increment) { $0.count = 2 }
            await model.finish()
        }

        #expect(issues.map(\.line) == [sendLine])
        #expect(issues.map(\.heading) == ["A state change does not match expectation."])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func customFeatureStateEqualityDrivesAssertions() async {
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: ComparableTestState(),
                feature: Feature(interactor: ComparableTestInteractor(), areStatesEqual: { $0.count == $1.count })
            )
            await model.send(.annotate("ignored"))  // `note` is outside the comparison
            await model.send(.increment) { $0.count = 1 }
            #expect(await model.state == ComparableTestState(count: 1, note: "ignored"))
            await model.finish()
        }

        #expect(issues == [])
    }
}
