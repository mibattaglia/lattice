import Testing

@testable import UnoArchitecture

@Suite
@MainActor
struct InteractorTestHarnessTests {
    @Test
    func sendActionsAndAssertStates() throws {
        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: CounterInteractor()
        )

        harness.send(.increment)
        harness.send(.increment)
        harness.send(.decrement)

        try harness.assertStates([
            CounterInteractor.State(count: 0),
            CounterInteractor.State(count: 1),
            CounterInteractor.State(count: 2),
            CounterInteractor.State(count: 1),
        ])
    }

    @Test
    func assertLatestState() throws {
        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: CounterInteractor()
        )

        harness.send(.increment)
        harness.send(.increment)

        try harness.assertLatestState(CounterInteractor.State(count: 2))
    }
}
