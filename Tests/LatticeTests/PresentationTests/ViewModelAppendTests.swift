import Foundation
import Testing

@testable import Lattice

@ObservableState
private struct AppendViewState: Equatable, Sendable {
    var log: [String] = []
}

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

    private func makeViewModel()
        -> ViewModel<Feature<AppendInteractor.Action, AppendInteractor.State, AppendViewState>>
    {
        ViewModel(
            initialDomainState: AppendInteractor.State(),
            feature: Feature(
                interactor: AppendInteractor(),
                reducer: BuildViewState(
                    initial: { _ in AppendViewState() },
                    reducerBlock: { domainState, viewState in
                        viewState.log = domainState.log
                    }
                )
            )
        )
    }

    @Test
    func appendedPerformsExecuteInOrder() async throws {
        let viewModel = makeViewModel()

        await viewModel.sendViewEvent(.appendTwoPerforms).finish()

        #expect(viewModel.viewState.log == ["first", "second"])
    }

    @Test
    func appendWaitsForInnerMergeBeforeNext() async throws {
        let viewModel = makeViewModel()

        await viewModel.sendViewEvent(.appendMergeThenPerform).finish()

        #expect(viewModel.viewState.log.contains("merge-a"))
        #expect(viewModel.viewState.log.contains("merge-b"))
        #expect(viewModel.viewState.log.last == "after-merge")
    }

    @Test
    func nilPerformDoesNotBlockNextStep() async throws {
        let viewModel = makeViewModel()

        await viewModel.sendViewEvent(.appendPerformReturningNil).finish()

        #expect(viewModel.viewState.log == ["after-nil"])
    }

    @Test
    func cancelStopsRemainingAppendedSteps() async throws {
        let viewModel = makeViewModel()

        let task = viewModel.sendViewEvent(.appendTwoPerforms)
        task.cancel()
        await task.finish()

        // At most the first step ran; second should not have started
        #expect(viewModel.viewState.log.count <= 1)
    }

    @Test
    func finishAwaitsAllAppendedSteps() async throws {
        let viewModel = makeViewModel()

        let task = viewModel.sendViewEvent(.appendTwoPerforms)
        #expect(task.hasEffects)

        await task.finish()
        #expect(viewModel.viewState.log.count == 2)
    }

    @Test
    func mergeRemainsUnaffected() async throws {
        let viewModel = makeViewModel()

        await viewModel.sendViewEvent(.appendMergeThenPerform).finish()

        // merge-a and merge-b both appear before after-merge
        let indexA = viewModel.viewState.log.firstIndex(of: "merge-a")!
        let indexB = viewModel.viewState.log.firstIndex(of: "merge-b")!
        let indexAfter = viewModel.viewState.log.firstIndex(of: "after-merge")!

        #expect(indexA < indexAfter)
        #expect(indexB < indexAfter)
    }
}
