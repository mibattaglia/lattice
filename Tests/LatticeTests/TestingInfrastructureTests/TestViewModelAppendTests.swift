import Foundation
import Testing

@testable import Lattice

@ObservableState
private struct AppendState: Equatable, Sendable {
    var log: [String] = []
}

private enum AppendAction: Equatable, Sendable {
    case runSequence
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
    func eventTaskFinishWaitsForEntireAppendSequenceWithoutDrainingReceives() async throws {
        let model = makeModel()

        let task = try await model.send(.runSequence)
        try await task.finish()

        #expect(model.domainState.log.isEmpty)

        try await model.receive(.logged("first")) {
            $0.log = ["first"]
        }
        try await model.receive(.logged("second")) {
            $0.log = ["first", "second"]
        }
        try await model.receive(.logged("third")) {
            $0.log = ["first", "second", "third"]
        }
    }

    private func makeModel() -> TestViewModel<Feature<AppendAction, AppendState, AppendState>> {
        TestViewModel(
            initialDomainState: AppendState(),
            feature: Feature(interactor: AppendSequenceInteractor())
        )
    }
}
