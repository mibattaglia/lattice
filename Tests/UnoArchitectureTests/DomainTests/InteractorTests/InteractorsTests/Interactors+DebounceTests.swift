import Clocks
import Foundation
import Testing

@testable import UnoArchitecture

@Suite(.serialized)
@MainActor
struct DebounceInteractorTests {

    @Test
    func stateChangesImmediately() async throws {
        let clock = TestClock()

        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            clock: clock
        ) {
            CounterInteractor()
        }

        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: debounced
        )

        #expect(harness.states == [.init(count: 0)])

        // Send action - state changes IMMEDIATELY (effect-level debouncing)
        harness.send(.increment)

        // State already changed
        #expect(harness.states == [.init(count: 0), .init(count: 1)])
    }

    @Test
    func allActionsProcessedImmediately() async throws {
        let clock = TestClock()

        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            clock: clock
        ) {
            CounterInteractor()
        }

        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: debounced
        )

        // Send multiple rapid actions - ALL state changes happen immediately
        harness.send(.increment)
        harness.send(.increment)
        harness.send(.increment)

        // All three increments processed immediately
        #expect(harness.states == [
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3)
        ])
    }

    @Test
    func effectsAreDebounced() async throws {
        let clock = TestClock()
        let effectExecutionCount = Counter()

        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            clock: clock
        ) {
            EffectInteractor(counter: effectExecutionCount)
        }

        let harness = InteractorTestHarness(
            initialState: EffectInteractor.State(),
            interactor: debounced
        )

        // Send multiple triggers rapidly
        harness.send(.trigger)
        harness.send(.trigger)
        let task = harness.send(.trigger)

        // All state changes happened immediately
        #expect(harness.currentState.triggerCount == 3)

        // But NO effects have executed yet
        #expect(await effectExecutionCount.value == 0)

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))
        await task.finish()

        // Only ONE effect executed (the last one)
        #expect(await effectExecutionCount.value == 1)

        // Effect result reflects the last trigger
        #expect(harness.currentState.effectResult == 3)
    }

    @Test
    func noneEmissionsPassThrough() async throws {
        let clock = TestClock()

        // CounterInteractor returns .none, should work fine
        let debounced = Interactors.Debounce(
            for: .milliseconds(300),
            clock: clock
        ) {
            CounterInteractor()
        }

        let harness = InteractorTestHarness(
            initialState: CounterInteractor.State(count: 0),
            interactor: debounced
        )

        harness.send(.increment)
        harness.send(.decrement)
        harness.send(.increment)

        // All processed immediately since .none emissions pass through
        #expect(harness.currentState.count == 1)
    }
}

// MARK: - Test Helpers

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

private struct EffectInteractor: Interactor, Sendable {
    typealias DomainState = State

    struct State: Equatable, Sendable {
        var triggerCount: Int = 0
        var effectResult: Int = 0
    }

    enum Action: Sendable, Equatable {
        case trigger
        case effectCompleted(Int)
    }

    let counter: Counter

    var body: some InteractorOf<Self> { self }

    func interact(state: inout State, action: Action) -> Emission<Action> {
        switch action {
        case .trigger:
            state.triggerCount += 1
            let count = state.triggerCount
            return .perform { [counter] in
                await counter.increment()
                return .effectCompleted(count)
            }
        case .effectCompleted(let result):
            state.effectResult = result
            return .none
        }
    }
}
