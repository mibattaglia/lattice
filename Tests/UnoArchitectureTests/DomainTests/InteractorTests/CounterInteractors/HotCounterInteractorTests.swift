@preconcurrency import Combine
import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
final class HotCounterInteractorTests {

    @Test func asyncWork() async throws {
        let harness = InteractorTestHarness(
            initialState: HotCounterInteractor.DomainState(count: 0),
            interactor: HotCounterInteractor()
        )

        harness.send(.increment)

        let intPublisher = CurrentValueSubject<Int, Never>(1)
        let observeTask = harness.send(.observe(intPublisher.eraseToAnyPublisher()))

        // Allow the CurrentValueSubject's initial value (1) to propagate
        try await Task.sleep(for: .milliseconds(50))

        intPublisher.send(2)
        try await Task.sleep(for: .milliseconds(50))

        harness.send(.increment)
        intPublisher.send(completion: .finished)
        await observeTask.finish()

        try harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 4),
            .init(count: 5),
        ])
    }
}
