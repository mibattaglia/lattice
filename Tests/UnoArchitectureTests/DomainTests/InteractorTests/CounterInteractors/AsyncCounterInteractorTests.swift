import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
final class AsyncCounterInteractorTests {

    @Test func asyncWork() async throws {
        let interactor = AsyncCounterInteractor()
        let harness = InteractorTestHarness(
            initialState: AsyncCounterInteractor.State(count: 0),
            interactor: interactor
        )

        harness.send(.increment)
        await harness.send(.async).finish()
        await Task.yield()
        harness.send(.increment)

        try harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
        ])
    }
}
