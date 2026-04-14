import CasePaths
import Foundation
import Testing

@testable import Lattice

@ObservableState
private struct TestSendState: Equatable, Sendable {
    var count = 0
}

@CasePathable
private enum TestSendAction: Equatable, Sendable {
    case increment
    case load
    case loaded(Int)
}

@Interactor<TestSendState, TestSendAction>
private struct TestSendInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none

            case .load:
                state.count += 1
                return .perform { .loaded(41) }

            case .loaded(let value):
                state.count += value
                return .none
            }
        }
    }
}

@Suite
@MainActor
struct TestViewModelSendTests {
    @Test
    func sendBuffersEmittedActionsUntilReceive() async throws {
        let model = makeModel()

        let task = try await model.send(.load) {
            $0.count = 1
        }

        #expect(task.hasEffects)
        #expect(model.domainState.count == 1)

        try await model.receive(.loaded(41)) {
            $0.count = 42
        }

        #expect(model.domainState.count == 42)
    }

    @Test
    func receiveSupportsPredicateMatching() async throws {
        let model = makeModel()

        _ = try await model.send(.load) {
            $0.count = 1
        }

        try await model.receive(
            {
                if case .loaded = $0 {
                    return true
                }
                return false
            }
        ) {
            $0.count = 42
        }

        #expect(model.domainState.count == 42)
    }

    @Test
    func receiveSupportsCasePathMatching() async throws {
        let model = makeModel()

        _ = try await model.send(.load) {
            $0.count = 1
        }

        try await model.receive(\.loaded) {
            $0.count = 42
        }

        #expect(model.domainState.count == 42)
    }

    private func makeModel() -> TestViewModel<Feature<TestSendAction, TestSendState, TestSendState>> {
        TestViewModel(
            initialDomainState: TestSendState(),
            feature: Feature(interactor: TestSendInteractor())
        )
    }
}
