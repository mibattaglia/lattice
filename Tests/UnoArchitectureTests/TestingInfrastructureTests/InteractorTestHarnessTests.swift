import Testing

@testable import UnoArchitecture

@Suite
@MainActor
struct InteractorTestHarnessTests {
    @Test
    func sendActionsAndAssertStates() async throws {
        let harness = await InteractorTestHarness(CounterInteractor())

        harness.send(.increment)
        harness.send(.increment)
        harness.send(.decrement)

        try await harness.assertStates([
            CounterInteractor.State(count: 0),
            CounterInteractor.State(count: 1),
            CounterInteractor.State(count: 2),
            CounterInteractor.State(count: 1),
        ])
    }

    @Test
    func assertLatestState() async throws {
        let harness = await InteractorTestHarness(CounterInteractor())

        harness.send(.increment)
        harness.send(.increment)

        try await harness.waitForStates(count: 3)
        try await harness.assertLatestState(CounterInteractor.State(count: 2))
    }
}
