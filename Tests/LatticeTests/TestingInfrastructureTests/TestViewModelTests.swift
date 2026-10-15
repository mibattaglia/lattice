import CasePaths
import Foundation
import Testing

@testable import Lattice

/// Main-actor state an interactor captures: what `TestModel` cannot host and `TestViewModel` exists
/// for.
@MainActor
final class MainActorRecorder {
    var entries: [String] = []
}

/// The `TestModel` contract on the main-actor shell: `send` and `init` are synchronous, and
/// `exhaustivity` and `timeout` are settable properties.
@MainActor
@Suite
struct TestViewModelTests {
    private func makeModel(
        _ interactor: LoadInteractor = LoadInteractor(),
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> TestViewModel<Feature<LoadAction, LoadState>> {
        TestViewModel(
            initialState: LoadState(),
            feature: Feature(interactor: interactor),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    @Test
    func sendReceiveExpectAndFinish() async {
        let issues = await reportedIssueDetails {
            let model = makeModel()

            let task = model.send(.load) { $0.count = 1 }
            #expect(task != nil)
            #expect(model.state.count == 1)  // the asserted state: `.loaded(41)` is pending
            await model.receive(.loaded(41)) { $0.count = 42 }

            model.send(.preamble) {  // the preamble's modification is folded into the send
                $0.note = "go"
                $0.count = 52
            }

            await model.send(.fetch)?.value
            model.expect {
                $0.count = 5
                $0.note = "x"
            }

            model.send(.startSequence)
            await model.receive({ $0 == .step(1) }) { $0.values = [1] }
            await model.receive(\.step) { $0.values = [1, 2] }
            await model.finish()
        }

        #expect(issues == [])
    }

    @Test
    func assertionsThatFailAreReportedAtTheCaller() async {
        var lines: [Int] = []
        let issues = await reportedIssueDetails {
            let model = makeModel()
            lines.append(#line + 1)
            model.send(.increment) { $0.count = 2 }
            lines.append(#line + 1)
            await model.receive(.loaded(41))  // nothing in flight: fails at once
            await model.send(.fetch)?.value
            lines.append(#line + 1)
            model.expect { $0.count = 5 }
            await model.finish()
        }

        #expect(issues.map(\.line) == lines)
        #expect(
            issues.map(\.heading) == [
                "A state change does not match expectation.",
                "Expected to receive the following action, but didn't:",
                "A state change does not match expectation.",
            ]
        )
    }

    /// Exhaustive leftovers are reported at the next `send` and at `finish`; with
    /// `exhaustivity = .off(showSkippedAssertions: false)` they are skipped silently.
    @Test
    func exhaustivityIsASettableProperty() async {
        var lines: [Int] = []
        let issues = await reportedIssueDetails {
            let model = makeModel()
            model.send(.startSequence)
            lines.append(#line + 1)
            model.send(.increment) { $0.count = 1 }

            model.exhaustivity = .off(showSkippedAssertions: false)
            model.send(.startSequence)
            model.send(.increment) { $0.count = 2 }

            model.exhaustivity = .on
            await model.send(.fetch)?.value
            lines.append(#line + 1)
            await model.finish()
        }

        #expect(issues.map(\.line) == lines)
        #expect(issues.map(\.isWarning) == [false, false])
        #expect(
            issues.map(\.heading) == [
                "Must handle 2 received actions before sending another action.",
                "Received 2 unasserted modifications left unhandled.",
            ]
        )
    }

    @Test
    func finishTimesOutAfterTheSettableTimeoutAndSkipInFlightEffectsCancels() async {
        let log = EffectLog()
        var lines: [Int] = []
        let issues = await reportedIssueDetails {
            let model = makeModel(LoadInteractor(log: log))
            model.timeout = .milliseconds(20)
            model.send(.hang)
            lines.append(#line + 1)
            await model.finish()
            model.timeout = .seconds(5)
            await model.skipInFlightEffects()
            lines.append(#line + 1)
            await model.skipInFlightEffects()
            await model.finish()
        }

        #expect(issues.map(\.line) == lines)
        #expect(
            issues.map(\.message) == [
                "Expected effects to finish, but 1 effect remained in flight after 0.02 seconds.",
                "There were no in-flight effects to skip.",
            ]
        )
        #expect(log.entries == ["hang cancelled"])
    }

    @Test
    func skipReceivedSkipsActionsAndModifications() async {
        var strictSkipLine = 0
        let issues = await reportedIssueDetails {
            let model = makeModel()
            await model.send(.modifyTwiceThenSend)?.value  // two modifications, then `.step(7)`
            model.skipReceived()
            #expect(model.state == LoadState(count: 7, note: "seven", values: [7]))
            strictSkipLine = #line + 1
            model.skipReceived()
            await model.finish()
        }

        #expect(issues.map(\.line) == [strictSkipLine])
        #expect(issues.map(\.message) == ["There were no received actions or modifications to skip."])
    }

    @Test
    func missingStateEqualityIsReportedAtInitAndAtEveryAssertion() async {
        var lines: [Int] = []
        let issues = await reportedIssueDetails {
            let feature = Feature(interactor: UncomparableTestInteractor())
            lines.append(#line + 1)
            let model = TestViewModel(initialState: UncomparableTestState(), feature: feature)
            lines.append(#line + 1)
            model.send(.increment) { $0.count = 1 }
            await model.finish()
        }

        #expect(issues.map(\.line) == lines)
        #expect(issues.map(\.heading) == [missingStateEqualityHeading, missingStateEqualityHeading])
    }

    /// An interactor formed on the main actor, capturing main-actor state: main-actor-isolated,
    /// which `TestModel` rejects at compile time (`MAINACTOR_INTERACTOR_TO_TESTMODEL`).
    @Test
    func mainActorFormedInteractorRunsUnderTheTestViewModel() async {
        let recorder = MainActorRecorder()
        let interactor = Interact<LoadState, LoadAction> { state, action, effects in
            guard action == .fetch else { return }
            recorder.entries.append("interact")
            effects.perform {
                await Task.yield()
                MainActor.assertIsolated("The effect resumed off the main actor")
                recorder.entries.append("effect")
                try effects.modify { $0.count = 5 }
            }
        }
        let issues = await reportedIssueDetails {
            let model = TestViewModel(initialState: LoadState(), feature: Feature(interactor: interactor))
            await model.send(.fetch)?.value
            model.expect { $0.count = 5 }
            await model.finish()
        }

        #expect(issues == [])
        #expect(recorder.entries == ["interact", "effect"])
    }
}
