import Clocks
import Foundation
import Testing

@testable import UnoArchitecture

@Suite
struct DebouncerTests {

    // MARK: - Test 1: Debounce delays execution

    @Test
    func debounceDelaysExecution() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer(for: .milliseconds(300), clock: clock)

        // Schedule work
        let task = await debouncer.debounce {
            await counter.increment()
        }

        // Work should NOT have executed yet
        #expect(await counter.value == 0)

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))
        await task.value

        // Now work should have executed
        #expect(await counter.value == 1)
    }

    // MARK: - Test 2: Rapid actions are coalesced

    @Test
    func debounceCoalescesRapidActions() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer(for: .milliseconds(300), clock: clock)

        // Schedule work 3 times rapidly
        await debouncer.debounce { await counter.increment() }
        await debouncer.debounce { await counter.increment() }
        let task = await debouncer.debounce { await counter.increment() }

        // Work should NOT have executed yet
        #expect(await counter.value == 0)

        // Advance past debounce period
        await clock.advance(by: .seconds(1))
        await task.value

        // Only ONE execution (coalesced)
        #expect(await counter.value == 1)
    }

    // MARK: - Test 3: Only the last work closure executes

    @Test
    func debounceExecutesOnlyLastWork() async throws {
        let clock = TestClock()
        let result = ResultHolder()

        let debouncer = Debouncer(for: .milliseconds(300), clock: clock)

        // Schedule different work closures

        await debouncer.debounce { await result.set("first") }
        await debouncer.debounce { await result.set("second") }
        let task = await debouncer.debounce { await result.set("third") }

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))
        await task.value

        // Only the LAST closure should have executed
        #expect(await result.value == "third")
    }

    // MARK: - Edge Case: Task cancelled externally

    @Test
    func workDoesNotExecuteWhenTaskCancelled() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer(for: .milliseconds(300), clock: clock)

        let task = await debouncer.debounce {
            await counter.increment()
        }

        // Cancel task externally before debounce period elapses
        task.cancel()

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))
        await task.value

        // Work should NOT have executed
        #expect(await counter.value == 0)
    }

    // MARK: - Edge Case: Sequential calls with full gaps

    @Test
    func sequentialCallsWithGapsExecuteIndependently() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer(for: .milliseconds(300), clock: clock)

        // First call
        let task1 = await debouncer.debounce { await counter.increment() }
        await clock.advance(by: .milliseconds(300))
        await task1.value
        #expect(await counter.value == 1)

        // Second call after first completed
        let task2 = await debouncer.debounce { await counter.increment() }
        await clock.advance(by: .milliseconds(300))
        await task2.value
        #expect(await counter.value == 2)
    }

    // MARK: - Edge Case: Call mid-debounce resets timer

    @Test
    func callMidDebounceResetsTimer() async throws {
        let clock = TestClock()
        let result = ResultHolder()

        let debouncer = Debouncer(for: .milliseconds(300), clock: clock)

        // First call
        await debouncer.debounce { await result.set("first") }

        // Advance partially (not enough to trigger)
        await clock.advance(by: .milliseconds(200))
        #expect(await result.value == "")

        // Second call resets the timer
        let task = await debouncer.debounce { await result.set("second") }

        // Advance another 200ms (total 400ms, but only 200ms since second call)
        await clock.advance(by: .milliseconds(200))
        #expect(await result.value == "")

        // Advance remaining 100ms to complete second debounce
        await clock.advance(by: .milliseconds(100))
        await task.value

        // Only second work executed
        #expect(await result.value == "second")
    }
}

// MARK: - Test Helpers

/// Thread-safe counter for async tests
private actor Counter {
    var value = 0

    func increment() {
        value += 1
    }
}

/// Thread-safe result holder for async tests
private actor ResultHolder {
    var value = ""

    func set(_ newValue: String) {
        value = newValue
    }
}
