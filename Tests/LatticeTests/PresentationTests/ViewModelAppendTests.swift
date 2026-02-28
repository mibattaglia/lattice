import Foundation
import Testing

@testable import Lattice

@Suite(.serialized)
@MainActor
struct ViewModelAppendTests {

    @Interactor
    struct AppendInteractor {
        struct State: Equatable, Sendable {
            var log: [String] = []
        }

        enum Action: Sendable, Equatable {
            case appendTwoPerforms
            case appendMergeThenPerform
            case appendPerformReturningNil
            case logged(String)
        }

        var body: some Interactor<State, Action> {
            Interact { state, action in
                switch action {
                case .appendTwoPerforms:
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

                case .appendMergeThenPerform:
                    return .append(
                        .merge([
                            .perform { .logged("merge-a") },
                            .perform { .logged("merge-b") },
                        ]),
                        .perform { .logged("after-merge") }
                    )

                case .appendPerformReturningNil:
                    return .append(
                        .perform { nil },
                        .perform { .logged("after-nil") }
                    )

                case .logged(let entry):
                    state.log.append(entry)
                    return .none
                }
            }
        }
    }

    private func makeHarness() -> InteractorTestHarness<AppendInteractor.State, AppendInteractor.Action> {
        InteractorTestHarness(
            initialState: AppendInteractor.State(),
            interactor: AppendInteractor()
        )
    }

    @Test
    func appendedPerformsExecuteInOrder() async throws {
        let harness = makeHarness()

        await harness.send(.appendTwoPerforms).finish()

        #expect(harness.currentState.log == ["first", "second"])
    }

    @Test
    func appendWaitsForInnerMergeBeforeNext() async throws {
        let harness = makeHarness()

        await harness.send(.appendMergeThenPerform).finish()

        #expect(harness.currentState.log.contains("merge-a"))
        #expect(harness.currentState.log.contains("merge-b"))
        #expect(harness.currentState.log.last == "after-merge")
    }

    @Test
    func nilPerformDoesNotBlockNextStep() async throws {
        let harness = makeHarness()

        await harness.send(.appendPerformReturningNil).finish()

        #expect(harness.currentState.log == ["after-nil"])
    }

    @Test
    func cancelStopsRemainingAppendedSteps() async throws {
        let harness = makeHarness()

        let task = harness.send(.appendTwoPerforms)
        task.cancel()
        try? await Task.sleep(for: .milliseconds(50))

        // At most the first step ran; second should not have started
        #expect(harness.currentState.log.count <= 1)
    }

    @Test
    func finishAwaitsAllAppendedSteps() async throws {
        let harness = makeHarness()

        let task = harness.send(.appendTwoPerforms)
        #expect(task.hasEffects)

        await task.finish()
        #expect(harness.currentState.log.count == 2)
    }

    @Test
    func mergeRemainsUnaffected() async throws {
        let harness = makeHarness()

        await harness.send(.appendMergeThenPerform).finish()

        // merge-a and merge-b both appear before after-merge
        let indexA = harness.currentState.log.firstIndex(of: "merge-a")!
        let indexB = harness.currentState.log.firstIndex(of: "merge-b")!
        let indexAfter = harness.currentState.log.firstIndex(of: "after-merge")!

        #expect(indexA < indexAfter)
        #expect(indexB < indexAfter)
    }
}
