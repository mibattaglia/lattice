import Clocks
import Foundation
import Testing

@testable import UnoArchitecture

@Suite
@MainActor
struct DebounceTests {
    @Test
    func debounceDelaysActions() async throws {
        let clock = TestClock()

        let debounced = Interactors.Debounce<TestClock, CounterInteractor>(
            for: .milliseconds(300),
            clock: clock
        ) {
            CounterInteractor()
        }

        let recorder = AsyncStreamRecorder<CounterInteractor.State>()
        let (actionStream, actionCont) = AsyncStream<CounterInteractor.Action>.makeStream()

        recorder.record(debounced.interact(actionStream))

        // Wait for initial state
        try await recorder.waitForEmissions(count: 1, timeout: .seconds(2))
        #expect(recorder.values == [.init(count: 0)])

        // Send action
        actionCont.yield(.increment)

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))
        try await recorder.waitForEmissions(count: 2, timeout: .seconds(2))
        #expect(recorder.values == [.init(count: 0), .init(count: 1)])

        actionCont.finish()
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

        let recorder = AsyncStreamRecorder<CounterInteractor.State>()
        let (actionStream, actionCont) = AsyncStream<CounterInteractor.Action>.makeStream()

        recorder.record(debounced.interact(actionStream))

        // Wait for initial state
        try await recorder.waitForEmissions(count: 1, timeout: .seconds(2))
        #expect(recorder.values == [.init(count: 0)])

        // Send multiple rapid actions
        actionCont.yield(.increment)
        actionCont.yield(.increment)
        actionCont.yield(.increment)

        // Advance past debounce period
        await clock.advance(by: .seconds(1))
        try await recorder.waitForEmissions(count: 2, timeout: .seconds(2))

        // Only one state change because debounce emits only the last value
        #expect(recorder.values == [.init(count: 0), .init(count: 1)])

        actionCont.finish()
    }
}
