import Foundation
import Testing

@testable import Lattice

@ObservableState
private struct AppendState: Equatable, Sendable {
    var log: [String] = []
}

private enum AppendAction: Equatable, Sendable {
    case runSequence
    case hang
    case logged(String)
}

@Interactor<AppendState, AppendAction>
private struct AppendSequenceInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .runSequence:
                return .append(
                    .perform {
                        return .logged("first")
                    },
                    .perform {
                        return .logged("second")
                    },
                    .perform {
                        return .logged("third")
                    }
                )

            case .hang:
                return .perform {
                    try? await Task.sleep(for: .seconds(60))
                    return nil
                }

            case .logged(let value):
                state.log.append(value)
                return .none
            }
        }
    }
}

@Suite
@MainActor
struct TestViewModelAppendTests {
    @Test
    func eventTaskFinishWaitsForEntireAppendSequenceWithoutDrainingReceives() async {
        let model = makeModel()

        let task = await model.send(.runSequence)
        await task.finish()

        #expect(model.domainState.log.isEmpty)

        await model.receive(.logged("first")) {
            $0.log = ["first"]
        }
        await model.receive(.logged("second")) {
            $0.log = ["first", "second"]
        }
        await model.receive(.logged("third")) {
            $0.log = ["first", "second", "third"]
        }
    }

    @Test
    func eventTaskFinishTimeoutReportsAtCaller() async {
        let model = makeModel()
        let task = await model.send(.hang)

        let finishLine = #line + 1
        await expectIssue(containing: "Expected task to finish, but it remained in flight after 0.01 seconds.", line: finishLine) { await task.finish(timeout: .milliseconds(10)) }

        await task.cancel()
    }

    private func makeModel() -> TestViewModel<Feature<AppendAction, AppendState, AppendState>> {
        TestViewModel(
            initialDomainState: AppendState(),
            feature: Feature(interactor: AppendSequenceInteractor())
        )
    }
}
