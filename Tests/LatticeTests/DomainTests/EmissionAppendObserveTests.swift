import Foundation
import Testing

@testable import Lattice

private struct ObserveSequenceState: Equatable, Sendable {
    var log: [String] = []
}

private enum ObserveSequenceAction: Sendable, Equatable {
    case startObserveThenPerform
    case logged(String)
}

@Interactor<ObserveSequenceState, ObserveSequenceAction>
private struct ObserveSequenceInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .startObserveThenPerform:
                return .append(
                    .observe {
                        AsyncStream { continuation in
                            continuation.yield(.logged("stream-1"))
                            continuation.yield(.logged("stream-2"))
                            continuation.finish()
                        }
                    },
                    .perform { .logged("after-stream") }
                )

            case .logged(let entry):
                state.log.append(entry)
                return .none
            }
        }
    }
}

@Suite(.serialized)
@MainActor
struct EmissionAppendObserveTests {

    @Test
    func finiteObserveCompletesBeforeNextStep() async {
        let model = makeTestViewModel(
            initialDomainState: ObserveSequenceState(),
            interactor: ObserveSequenceInteractor()
        )

        let task = await model.send(.startObserveThenPerform)
        await task.finish()

        #expect(model.domainState.log.isEmpty)

        await model.receive(.logged("stream-1")) {
            $0.log = ["stream-1"]
        }
        await model.receive(.logged("stream-2")) {
            $0.log = ["stream-1", "stream-2"]
        }
        await model.receive(.logged("after-stream")) {
            $0.log = ["stream-1", "stream-2", "after-stream"]
        }
    }
}
