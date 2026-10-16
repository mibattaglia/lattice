import Foundation
import Testing

@testable import Lattice

// `EffectClockTests`' core shapes under `TestViewModel`, whose effects run on the main actor, as
// `TestViewModel.advance(_:by:)` does. The suite is `@MainActor`, so the interactor is formed there,
// as a main-actor feature's would be.

private let debounce: Duration = .milliseconds(300)
private let interval: Duration = .seconds(1)

@MainActor
private func makeViewModel(
    clock: EffectClock,
    log: EffectLog = EffectLog(),
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) -> TestViewModel<Feature<ClockAction, ClockState>> {
    TestViewModel(
        initialState: ClockState(),
        feature: Feature(interactor: ClockInteractor(clock: clock, debounce: debounce, interval: interval, log: log)),
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

@MainActor
@Suite
struct EffectClockTestViewModelTests {
    /// The sleep is registered when the synchronous `send` returns, and `advance` returns once the
    /// woken search has committed. Not a moment early: 1 ms short of the debounce, nothing ran.
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func advanceDeliversTheDebouncedResult(iteration: Int) async {
        let clock = EffectClock()
        let log = EffectLog()
        let issues = await reportedIssueDetails {
            let model = makeViewModel(clock: clock, log: log)

            model.send(.query("new")) { $0.query = "new" }
            #expect(clock.sleeperCount == 1)
            await model.advance(clock, by: debounce - .milliseconds(1))
            #expect(log.entries == [])

            await model.advance(clock, by: .milliseconds(1))
            #expect(log.entries == ["searched new"])
            model.expect { $0.results = ["NEW"] }
            #expect(clock.sleeperCount == 0)
            await model.finish()
        }

        #expect(issues == [])
    }

    /// One `advance` over five intervals ticks exactly five times on the main actor; cancelling the
    /// ticker removes its sleep inside `cancel()`.
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func advanceTicksOncePerInterval(iteration: Int) async {
        let clock = EffectClock()
        let issues = await reportedIssueDetails {
            let model = makeViewModel(clock: clock)

            let ticker = model.send(.start)
            #expect(clock.sleeperCount == 1)

            await model.advance(clock, by: interval * 5)
            model.expect { $0.tick = 5 }
            #expect(clock.pendingDeadlines == [EffectClock.Instant(offset: interval * 6)])

            await model.advance(clock, by: interval)
            model.expect { $0.tick = 6 }

            ticker?.cancel()
            #expect(clock.sleeperCount == 0)
            await model.finish()
        }

        #expect(issues == [])
    }

    /// A second query within the debounce replaces the first one inside its `send`: one `advance`
    /// makes exactly one search.
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func aSecondQueryWithinTheDebounceReplacesTheFirst(iteration: Int) async {
        let clock = EffectClock()
        let log = EffectLog()
        let issues = await reportedIssueDetails {
            let model = makeViewModel(clock: clock, log: log)

            model.send(.query("a")) { $0.query = "a" }
            await model.advance(clock, by: .milliseconds(100))
            model.send(.query("ab")) { $0.query = "ab" }
            #expect(clock.pendingDeadlines == [EffectClock.Instant(offset: .milliseconds(100) + debounce)])

            await model.advance(clock, by: debounce)
            #expect(log.entries == ["searched ab"])
            model.expect { $0.results = ["AB"] }
            await model.finish()
        }

        #expect(issues == [])
    }
}
