import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
final class CounterInteractorTests {

    @Test func increment() async throws {
        let harness = await InteractorTestHarness(CounterInteractor())

        harness.send(.increment, .increment, .increment)
        harness.finish()

        try await harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
        ])
    }

    @Test func decrement() async throws {
        let harness = await InteractorTestHarness(CounterInteractor())

        harness.send(.increment, .increment, .increment)
        harness.send(.decrement, .decrement, .decrement)
        harness.finish()

        try await harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
            .init(count: 2),
            .init(count: 1),
            .init(count: 0),
        ])
    }

    @Test func reset() async throws {
        let harness = await InteractorTestHarness(CounterInteractor())

        harness.send(.increment, .increment, .increment)
        harness.send(.reset)
        harness.finish()

        try await harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
            .init(count: 0),
        ])
    }
}
