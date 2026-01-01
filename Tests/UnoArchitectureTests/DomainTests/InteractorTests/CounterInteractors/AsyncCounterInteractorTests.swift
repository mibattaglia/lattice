import CombineSchedulers
import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
final class AsyncCounterInteractorTests {
    private let scheduler = DispatchQueue.test

    @Test func asyncWork() async throws {
        let interactor = AsyncCounterInteractor(scheduler: scheduler.eraseToAnyScheduler())
        let harness = await InteractorTestHarness(interactor)

        harness.send(.increment)
        harness.send(.async)
        await scheduler.advance(by: .seconds(0.51))
        await Task.yield()
        harness.send(.increment)
        await scheduler.advance(by: .seconds(0.51))
        await Task.yield()
        harness.finish()

        try await harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
        ])
    }
}
