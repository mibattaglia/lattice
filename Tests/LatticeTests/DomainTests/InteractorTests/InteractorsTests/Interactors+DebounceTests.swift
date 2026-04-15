import Clocks
import Foundation
import Testing

@testable import Lattice

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

        let model = makeTestViewModel(
            initialDomainState: CounterState(count: 0),
            interactor: debounced
        )

        #expect(model.domainState == .init(count: 0))

        // Send action - state changes IMMEDIATELY (effect-level debouncing)
        _ = try await model.send(.increment) {
            $0.count = 1
        }

        // State already changed
        #expect(model.domainState == .init(count: 1))
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

        let model = makeTestViewModel(
            initialDomainState: CounterState(count: 0),
            interactor: debounced
        )

        // Send multiple rapid actions - ALL state changes happen immediately
        _ = try await model.send(.increment) { $0.count = 1 }
        _ = try await model.send(.increment) { $0.count = 2 }
        _ = try await model.send(.increment) { $0.count = 3 }

        // All three increments processed immediately
        #expect(model.domainState == .init(count: 3))
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

        let model = makeTestViewModel(
            initialDomainState: EffectInteractor.State(),
            interactor: debounced
        )

        // Send multiple triggers rapidly
        _ = try await model.send(.trigger) { $0.triggerCount = 1 }
        _ = try await model.send(.trigger) { $0.triggerCount = 2 }
        let task = try await model.send(.trigger) { $0.triggerCount = 3 }

        // All state changes happened immediately
        #expect(model.domainState.triggerCount == 3)

        // But NO effects have executed yet
        #expect(await effectExecutionCount.value == 0)

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))
        try await task.finish()

        // Only ONE effect executed (the last one)
        #expect(await effectExecutionCount.value == 1)

        // Effect result reflects the last trigger
        try await model.receive(.effectCompleted(3)) {
            $0.effectResult = 3
        }
        #expect(model.domainState.effectResult == 3)
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

        let model = makeTestViewModel(
            initialDomainState: CounterState(count: 0),
            interactor: debounced
        )

        _ = try await model.send(.increment) { $0.count = 1 }
        _ = try await model.send(.decrement) { $0.count = 0 }
        _ = try await model.send(.increment) { $0.count = 1 }

        // All processed immediately since .none emissions pass through
        #expect(model.domainState.count == 1)
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
