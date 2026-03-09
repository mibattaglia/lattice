import Foundation
import Testing

@testable import Lattice

@ObservableState
private struct AppendViewState: Equatable, Sendable {
    var log: [String] = []
}

@Interactor<AppendViewState, AppendAction>
private struct AppendViewInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .runSequence:
                return .append(
                    .perform {
                        try? await Task.sleep(for: .milliseconds(10))
                        return .logged("first")
                    },
                    .perform {
                        try? await Task.sleep(for: .milliseconds(10))
                        return .logged("second")
                    }
                )

            case .logged(let entry):
                state.log.append(entry)
                return .none
            }
        }
    }
}

private enum AppendAction: Sendable, Equatable {
    case runSequence
    case logged(String)
}

@MainActor
@Suite(.serialized)
struct ViewModelAppendRuntimeTests {
    @Test
    func appendedPerformsStillExecuteInOrder() async {
        let viewModel = ViewModel(
            initialDomainState: AppendViewState(),
            feature: Feature(interactor: AppendViewInteractor())
        )

        await viewModel.sendViewEvent(.runSequence).finish()

        #expect(viewModel.viewState.log == ["first", "second"])
    }
}
