import Foundation
import Testing

@testable import Lattice

@Suite(.serialized)
@MainActor
struct EmissionAppendObserveTests {

    @Interactor
    struct ObserveSequenceInteractor {
        struct State: Equatable, Sendable {
            var log: [String] = []
        }

        enum Action: Sendable, Equatable {
            case startObserveThenPerform
            case logged(String)
        }

        var body: some Interactor<State, Action> {
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

    @Test
    func finiteObserveCompletesBeforeNextStep() async throws {
        let harness = InteractorTestHarness(
            initialState: ObserveSequenceInteractor.State(),
            interactor: ObserveSequenceInteractor()
        )

        await harness.send(.startObserveThenPerform).finish()

        #expect(harness.currentState.log == ["stream-1", "stream-2", "after-stream"])
    }
}
