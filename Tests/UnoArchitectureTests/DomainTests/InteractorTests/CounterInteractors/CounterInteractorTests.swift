import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
final class CounterInteractorTests {

    @Test func increment() throws {
        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: CounterInteractor()
        )

        harness.send(.increment, .increment, .increment)

        try harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
        ])
    }

    @Test func decrement() throws {
        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: CounterInteractor()
        )

        harness.send(.increment, .increment, .increment)
        harness.send(.decrement, .decrement, .decrement)

        try harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
            .init(count: 2),
            .init(count: 1),
            .init(count: 0),
        ])
    }

    @Test func reset() throws {
        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: CounterInteractor()
        )

        harness.send(.increment, .increment, .increment)
        harness.send(.reset)

        try harness.assertStates([
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
            .init(count: 0),
        ])
    }
}
