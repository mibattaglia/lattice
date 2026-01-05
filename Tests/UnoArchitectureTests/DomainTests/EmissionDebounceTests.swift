import Clocks
import Foundation
import Testing

@testable import UnoArchitecture

@Suite(.serialized)
@MainActor
struct EmissionDebounceTests {

    enum TestAction: Sendable, Equatable {
        case result(Int)
    }

    @Test
    func debounceDelaysPerformEmission() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let emission = Emission<TestAction>.perform {
            .result(42)
        }.debounce(using: debouncer)

        guard case .perform(let work) = emission.kind else {
            Issue.record("Expected .perform emission")
            return
        }

        async let resultTask = work()

        await clock.advance(by: .milliseconds(300))

        let result = await resultTask
        #expect(result == .result(42))
    }

    @Test
    func debounceCoalescesRapidPerformEmissions() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let emission1 = Emission<TestAction>.perform { .result(1) }.debounce(using: debouncer)
        let emission2 = Emission<TestAction>.perform { .result(2) }.debounce(using: debouncer)
        let emission3 = Emission<TestAction>.perform { .result(3) }.debounce(using: debouncer)

        guard case .perform(let work1) = emission1.kind,
              case .perform(let work2) = emission2.kind,
              case .perform(let work3) = emission3.kind else {
            Issue.record("Expected .perform emissions")
            return
        }

        // Start all three concurrently
        async let r1 = work1()
        async let r2 = work2()
        async let r3 = work3()

        await clock.advance(by: .milliseconds(300))

        let results = await [r1, r2, r3]

        // Exactly one should have a value, two should be nil
        let nonNilCount = results.compactMap { $0 }.count
        let nilCount = results.filter { $0 == nil }.count

        #expect(nonNilCount == 1, "Exactly one emission should produce an action")
        #expect(nilCount == 2, "Two emissions should produce nil (superseded)")
    }

    @Test
    func executedNilAtDebounceLevel() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let emission = Emission<TestAction>.perform {
            nil
        }.debounce(using: debouncer)

        guard case .perform(let work) = emission.kind else {
            Issue.record("Expected .perform emission")
            return
        }

        async let r = work()
        await clock.advance(by: .milliseconds(300))

        let result = await r
        #expect(result == nil, "Work executed and intentionally returned nil")
    }

    @Test
    func noneEmissionPassesThrough() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let emission = Emission<TestAction>.none.debounce(using: debouncer)

        guard case .none = emission.kind else {
            Issue.record("Expected .none emission")
            return
        }
    }

    @Test
    func actionEmissionPassesThrough() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let emission = Emission<TestAction>.action(.result(42)).debounce(using: debouncer)

        guard case .action(let action) = emission.kind else {
            Issue.record("Expected .action emission")
            return
        }

        #expect(action == .result(42))
    }

    @Test
    func observeEmissionPassesThrough() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let emission = Emission<TestAction>.observe {
            AsyncStream { continuation in
                continuation.yield(.result(1))
                continuation.finish()
            }
        }.debounce(using: debouncer)

        guard case .observe = emission.kind else {
            Issue.record("Expected .observe emission - observe should pass through unchanged")
            return
        }
    }

    @Test
    func mergeDebouncesPeformChildren() async throws {
        let clock = TestClock()
        let debouncer = Debouncer<TestClock, TestAction?>(for: .milliseconds(300), clock: clock)

        let perform1 = Emission<TestAction>.perform { .result(1) }
        let perform2 = Emission<TestAction>.perform { .result(2) }
        let merged = Emission<TestAction>.merge([perform1, perform2]).debounce(using: debouncer)

        guard case .merge(let emissions) = merged.kind else {
            Issue.record("Expected .merge emission")
            return
        }

        #expect(emissions.count == 2)

        guard case .perform(let work1) = emissions[0].kind,
              case .perform(let work2) = emissions[1].kind else {
            Issue.record("Expected .perform emissions inside merge")
            return
        }

        async let r1 = work1()
        async let r2 = work2()

        await clock.advance(by: .milliseconds(300))

        let results = await [r1, r2]

        // One should execute, one should be superseded
        let nonNilCount = results.compactMap { $0 }.count
        #expect(nonNilCount == 1, "Merged perform emissions share debouncer, so only one executes")
    }
}
