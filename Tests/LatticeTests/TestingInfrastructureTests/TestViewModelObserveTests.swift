import Foundation
import Testing

@testable import Lattice

@ObservableState
private struct ObserveState: Equatable, Sendable {
    var log: [String] = []
}

private enum ObserveAction: Equatable, Sendable {
    case start
    case logged(String)
}

@Interactor<ObserveState, ObserveAction>
private struct ObserveSequenceInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .start:
                return .observe {
                    AsyncStream { continuation in
                        continuation.yield(.logged("stream-1"))
                        continuation.yield(.logged("stream-2"))
                        continuation.finish()
                    }
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
struct TestViewModelObserveTests {
    @Test
    func observeEmissionsStayBufferedUntilReceived() async {
        let model = makeModel()

        let task = await model.send(.start)
        await task.finish()

        #expect(model.domainState.log.isEmpty)

        await model.receive(.logged("stream-1")) {
            $0.log = ["stream-1"]
        }
        await model.receive(.logged("stream-2")) {
            $0.log = ["stream-1", "stream-2"]
        }
    }

    private func makeModel() -> TestViewModel<Feature<ObserveAction, ObserveState, ObserveState>> {
        TestViewModel(
            initialDomainState: ObserveState(),
            feature: Feature(interactor: ObserveSequenceInteractor())
        )
    }
}
