import Clocks
import Foundation
import Testing

@testable import UnoArchitecture

@Suite(.serialized)
@MainActor
struct DebounceInteractorTests {
    @Test
    func debounceDelaysActions() async throws {
        let clock = TestClock()

        let debounced = Interactors.Debounce<TestClock, CounterInteractor>(
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

        // Send action
        let task = harness.send(.increment)
        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))
        await task.finish()
        await Task.megaYield()

        #expect(harness.states == [.init(count: 0), .init(count: 1)])
    }

    @Test
    func debounceCoalescesRapidActions() async throws {
        let clock = TestClock()

        let debounced = Interactors.Debounce<TestClock, CounterInteractor>(
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

        // Send multiple rapid actions
        harness.send(.increment)
        harness.send(.increment)
        let task = harness.send(.increment)

        // Advance past debounce period
        await clock.advance(by: .seconds(1))
        await task.finish()

        // Only one state change because debounce emits only the last value
        #expect(harness.states == [.init(count: 0), .init(count: 1)])
    }
}
