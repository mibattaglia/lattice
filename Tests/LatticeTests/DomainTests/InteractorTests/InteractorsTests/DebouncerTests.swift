import Clocks
import Foundation
import Testing

@testable import Lattice

@Suite
struct DebouncerTests {

    // MARK: - Basic Execution Tests

    @Test
    func debounceReturnsExecutedAfterDuration() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)

        let task = await debouncer.debounce { 42 }

        await clock.advance(by: .milliseconds(300))

        #expect(await task.value == .executed(42))
    }

    @Test
    func debounceDelaysExecution() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)

        let task = await debouncer.debounce {
            await counter.increment()
            return await counter.value
        }

        // Work should NOT have executed yet
        #expect(await counter.value == 0)

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))

        // Now work should have executed
        #expect(await task.value == .executed(1))
        #expect(await counter.value == 1)
    }

    // MARK: - Superseded Tests

    @Test
    func onlyLastCallerGetsExecutedResult() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, String>(for: .milliseconds(300), clock: clock)

        // Sequential calls ensure deterministic ordering via actor serialization
        // Each call returns a Task immediately; we collect them without awaiting values
        let task1 = await debouncer.debounce { "first" }
        let task2 = await debouncer.debounce { "second" }
        let task3 = await debouncer.debounce { "third" }

        await clock.advance(by: .milliseconds(300))

        // First two are superseded, third executes
        #expect(await task1.value == .superseded)
        #expect(await task2.value == .superseded)
        #expect(await task3.value == .executed("third"))
    }

    @Test
    func onlyLastWorkClosureExecutes() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)
        let counter = Counter()

        // Sequential calls ensure deterministic ordering via actor serialization
        let task1 = await debouncer.debounce {
            await counter.increment()
            return 1
        }
        let task2 = await debouncer.debounce {
            await counter.increment()
            return 2
        }
        let task3 = await debouncer.debounce {
            await counter.increment()
            return 3
        }

        await clock.advance(by: .milliseconds(300))

        // Only the third closure executed
        #expect(await counter.value == 1)
        #expect(await task1.value == .superseded)
        #expect(await task2.value == .superseded)
        #expect(await task3.value == .executed(3))
    }

    // MARK: - Optional Value Tests

    @Test
    func executedNilIsDistinctFromSuperseded() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, Int?>(for: .milliseconds(300), clock: clock)

        // Work that intentionally returns nil
        let task = await debouncer.debounce { nil as Int? }

        await clock.advance(by: .milliseconds(300))

        // .executed(nil) is NOT the same as .superseded
        let value = await task.value
        #expect(value == .executed(nil))

        // Verify it's truly .executed, not .superseded
        if case .executed(let inner) = value {
            #expect(inner == nil)
        } else {
            Issue.record("Expected .executed(nil), got .superseded")
        }
    }

    // MARK: - Timer Reset Tests

    @Test
    func callMidDebounceResetsTimer() async throws {
        let clock = TestClock()
        let result = ResultHolder()

        let debouncer = Debouncer<TestClock, String>(for: .milliseconds(300), clock: clock)

        // First call - start debounce
        let task1 = await debouncer.debounce {
            await result.set("first")
            return "first"
        }

        // Advance partially (not enough to trigger)
        await clock.advance(by: .milliseconds(200))
        #expect(await result.value == "")

        // Second call resets the timer
        let task2 = await debouncer.debounce {
            await result.set("second")
            return "second"
        }

        // Advance another 200ms (total 400ms, but only 200ms since second call)
        await clock.advance(by: .milliseconds(200))
        #expect(await result.value == "")

        // Advance remaining 100ms to complete second debounce
        await clock.advance(by: .milliseconds(100))

        // Only second work executed
        #expect(await result.value == "second")
        #expect(await task1.value == .superseded)
        #expect(await task2.value == .executed("second"))
    }

    // MARK: - Cancellation Tests

    @Test
    func newCallCancelsPreviousWork() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)

        // First call starts debouncing
        let task1 = await debouncer.debounce {
            await counter.increment()
            return 1
        }

        // Second call should cancel the first
        let task2 = await debouncer.debounce {
            await counter.increment()
            return 2
        }

        // Advance past debounce period
        await clock.advance(by: .milliseconds(300))

        // Only second work executed, first was superseded
        #expect(await counter.value == 1)
        #expect(await task1.value == .superseded)
        #expect(await task2.value == .executed(2))
    }

    // MARK: - Sequential Independent Calls

    @Test
    func sequentialCallsWithGapsExecuteIndependently() async throws {
        let clock = TestClock()
        let counter = Counter()

        let debouncer = Debouncer<TestClock, Int>(for: .milliseconds(300), clock: clock)

        // First call
        let task1 = await debouncer.debounce {
            await counter.increment()
            return await counter.value
        }
        await clock.advance(by: .milliseconds(300))
        #expect(await task1.value == .executed(1))
        #expect(await counter.value == 1)

        // Second call after first completed
        let task2 = await debouncer.debounce {
            await counter.increment()
            return await counter.value
        }
        await clock.advance(by: .milliseconds(300))
        #expect(await task2.value == .executed(2))
        #expect(await counter.value == 2)
    }
}

// MARK: - Test Helpers

private actor Counter {
    var value = 0

    func increment() {
        value += 1
    }
}

private actor ResultHolder {
    var value = ""

    func set(_ newValue: String) {
        value = newValue
    }
}
