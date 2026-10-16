import Foundation
import Testing

@testable import Lattice

// `EffectClock` and `TestModel.advance(_:by:)`: an effect's `clock.sleep(for:)` registers on the
// model's executor before `send` returns, and `advance` lets each woken effect run to its next
// suspension before it wakes the next sleep, so an assertion right after it sees what the effect
// committed. The race-sensitive shapes repeat 25 times each.

private let debounce: Duration = .milliseconds(300)
private let interval: Duration = .seconds(1)

@available(iOS 26, macOS 26, watchOS 26, *)
private func makeModel<C: Clock<Duration>>(
    clock: C,
    log: EffectLog = EffectLog(),
    loadGate: SendableEffectGate = SendableEffectGate(),
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> TestModel<Feature<ClockAction, ClockState>> {
    await TestModel(
        initialState: ClockState(),
        feature: Feature(
            interactor: ClockInteractor(
                clock: clock,
                debounce: debounce,
                interval: interval,
                log: log,
                loadGate: loadGate
            )
        ),
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

/// Waits, yielding, until `clock` has a live sleep. Only for the bypass spellings, whose sleep
/// registers after `send` returns; the time limit ends a wait for a sleep that never comes.
private func waitUntilASleepIsRegistered(on clock: EffectClock) async {
    while clock.sleeperCount == 0, !Task.isCancelled {
        await Task.yield()
    }
}

@Suite
struct EffectClockTests {
    /// `clock.sleep(for:)` registers inside the effect's preamble, so the read right after `send`,
    /// with no `await` in between, sees the sleep; cancelling the effect removes it inside
    /// `cancel()`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func sleepIsRegisteredBeforeSendReturns(iteration: Int) async {
        let clock = EffectClock()
        let issues = await reportedIssueDetails {
            let model = await makeModel(clock: clock)

            let search = await model.send(.query("new")) { $0.query = "new" }
            #expect(clock.sleeperCount == 1)
            #expect(clock.pendingDeadlines == [EffectClock.Instant(offset: debounce)])

            search?.cancel()
            #expect(clock.sleeperCount == 0)
            await model.finish()
        }

        #expect(issues == [])
    }

    /// `advance` wakes the debounced search and returns once it has committed, so `expect` right
    /// after it sees the results. Not a moment early: 1 ms short of the debounce, nothing ran.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func advanceDeliversTheDebouncedResult(iteration: Int) async {
        let clock = EffectClock()
        let log = EffectLog()
        let issues = await reportedIssueDetails {
            let model = await makeModel(clock: clock, log: log)

            await model.send(.query("new")) { $0.query = "new" }
            await model.advance(clock, by: debounce - .milliseconds(1))
            #expect(clock.sleeperCount == 1)
            #expect(log.entries == [])

            await model.advance(clock, by: .milliseconds(1))
            #expect(log.entries == ["searched new"])
            await model.expect { $0.results = ["NEW"] }
            #expect(clock.sleeperCount == 0)
            #expect(clock.now == EffectClock.Instant(offset: debounce))
            await model.finish()
        }

        #expect(issues == [])
    }

    /// One `advance` over five intervals wakes the ticker five times, each time after it committed
    /// the previous tick and slept again: exactly five ticks, then exactly one more. Cancelling the
    /// ticker removes its sleep inside `cancel()`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func advanceTicksOncePerInterval(iteration: Int) async {
        let clock = EffectClock()
        let issues = await reportedIssueDetails {
            let model = await makeModel(clock: clock)

            let ticker = await model.send(.start)
            #expect(clock.sleeperCount == 1)

            await model.advance(clock, by: interval * 5)
            await model.expect { $0.tick = 5 }  // five modifications, one assertion
            #expect(clock.pendingDeadlines == [EffectClock.Instant(offset: interval * 6)])

            await model.advance(clock, by: interval)
            await model.expect { $0.tick = 6 }

            ticker?.cancel()
            #expect(clock.sleeperCount == 0)
            await model.finish()
        }

        #expect(issues == [])
    }

    /// The load is parked on its gate, not on the clock: `advance` does not wait for it. It ticks the
    /// ticker three times and returns while the load has committed nothing; opening the gate then
    /// finishes the load.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func advanceDoesNotWaitForAnEffectParkedElsewhere(iteration: Int) async {
        let clock = EffectClock()
        let loadGate = SendableEffectGate()
        let issues = await reportedIssueDetails {
            let model = await makeModel(clock: clock, loadGate: loadGate)

            let load = await model.send(.load)
            let ticker = await model.send(.start)
            await model.advance(clock, by: interval * 3)
            await model.expect { $0.tick = 3 }  // and no `isLoaded`: the load is still parked

            loadGate.open()
            await load?.value
            await model.expect { $0.isLoaded = true }
            ticker?.cancel()
            await model.finish()
        }

        #expect(issues == [])
    }

    /// A second query within the debounce auto-cancels the first one's sleep inside its `send`, so
    /// only the second sleep is left, and `advance` makes exactly one search.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func aSecondQueryWithinTheDebounceReplacesTheFirst(iteration: Int) async {
        let clock = EffectClock()
        let log = EffectLog()
        let issues = await reportedIssueDetails {
            let model = await makeModel(clock: clock, log: log)

            await model.send(.query("a")) { $0.query = "a" }
            await model.advance(clock, by: .milliseconds(100))
            await model.send(.query("ab")) { $0.query = "ab" }
            #expect(clock.pendingDeadlines == [EffectClock.Instant(offset: .milliseconds(100) + debounce)])

            await model.advance(clock, by: debounce)
            #expect(log.entries == ["searched ab"])
            await model.expect { $0.results = ["AB"] }
            await model.finish()
        }

        #expect(issues == [])
    }

    /// Clearing the query auto-cancels the waiting search: its sleep is gone when `send` returns, and
    /// moving time past it searches nothing.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func clearingTheQueryRemovesTheSleepInsideSend(iteration: Int) async {
        let clock = EffectClock()
        let log = EffectLog()
        let issues = await reportedIssueDetails {
            let model = await makeModel(clock: clock, log: log)

            await model.send(.query("new")) { $0.query = "new" }
            #expect(clock.sleeperCount == 1)
            await model.send(.query("")) { $0.query = "" }
            #expect(clock.sleeperCount == 0)

            await model.advance(clock, by: debounce)
            #expect(log.entries == [])
            await model.finish()
        }

        #expect(issues == [])
    }

    /// One `advance` over two intervals wakes the search at 300 ms and the ticker at 1 s and 2 s, in
    /// that order, and leaves the ticker asleep a full interval past the new time.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)), arguments: 1...25)
    func oneAdvanceWakesInterleavedSleepsInDeadlineOrder(iteration: Int) async {
        let clock = EffectClock()
        let log = EffectLog()
        let issues = await reportedIssueDetails {
            let model = await makeModel(clock: clock, log: log)

            let ticker = await model.send(.start)
            await model.send(.query("new")) { $0.query = "new" }
            #expect(
                clock.pendingDeadlines == [EffectClock.Instant(offset: debounce), EffectClock.Instant(offset: interval)]
            )

            await model.advance(clock, by: interval * 2)
            #expect(log.entries == ["searched new", "tick", "tick"])
            await model.expect {
                $0.results = ["NEW"]
                $0.tick = 2
            }
            #expect(clock.pendingDeadlines == [EffectClock.Instant(offset: interval * 3)])
            #expect(clock.now == EffectClock.Instant(offset: interval * 2))

            ticker?.cancel()
            await model.finish()
        }

        #expect(issues == [])
    }

    /// Every spelling that skips `clock.sleep(for:)` on the effect's isolation reaches the clock
    /// after a hop, so the sleep registers after `send` returned: each reports exactly one issue. The
    /// late sleep still works: `advance` wakes it once it registered, and the effect commits after it
    /// hops back to the model, so the test awaits it.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)), arguments: SleepSpelling.allCases)
    func eachBypassSpellingReportsTheLateSleepOnce(spelling: SleepSpelling) async {
        let clock = EffectClock()
        let log = EffectLog()
        let issues = await reportedIssueDetails {
            let model = await makeModel(clock: clock, log: log)

            let search = await model.send(.bypassQuery("x", spelling)) { $0.query = "x" }
            await waitUntilASleepIsRegistered(on: clock)
            await model.advance(clock, by: debounce)
            await search?.value
            await model.expect { $0.results = ["X"] }
            await model.finish()
        }

        #expect(issues.map(\.message) == [EffectClock.lateSleepMessage])
        #expect(log.entries == ["searched x"])
    }

    /// `clock.sleep(for:)` from the effect reports nothing, for a one-shot sleep and for a ticker.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func sleepForOnTheEffectsIsolationReportsNothing() async {
        let clock = EffectClock()
        let issues = await reportedIssueDetails {
            let model = await makeModel(clock: clock)

            await model.send(.query("x")) { $0.query = "x" }
            await model.advance(clock, by: debounce)
            await model.expect { $0.results = ["X"] }

            let ticker = await model.send(.start)
            await model.advance(clock, by: interval * 2)
            await model.expect { $0.tick = 2 }
            ticker?.cancel()
            await model.finish()
        }

        #expect(issues == [])
    }

    /// Not a bypass: `sleep(until:)` called on a concrete `EffectClock` runs on the effect's
    /// isolation, with no hop, so the sleep registers before `send` returns and nothing is reported.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func sleepUntilOnAConcreteEffectClockReportsNothing() async {
        let clock = EffectClock()
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: ClockState(),
                feature: Feature(interactor: ConcreteSleepUntilInteractor(clock: clock, delay: debounce))
            )

            await model.send(.query("x")) { $0.query = "x" }
            #expect(clock.sleeperCount == 1)
            await model.advance(clock, by: debounce)
            await model.expect { $0.results = ["X"] }
            await model.finish()
        }

        #expect(issues == [])
    }

    /// A clock that is not an `EffectClock` sleeps through `sleep(until:tolerance:)`, as the
    /// standard library's overload does: a `ContinuousClock` sleep takes its time, and the effect
    /// then commits on the model.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func aProductionClockSleepsForItsDuration() async {
        let log = EffectLog()
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: ClockState(),
                feature: Feature(
                    interactor: ClockInteractor(
                        clock: ContinuousClock(),
                        debounce: .milliseconds(20),
                        interval: interval,
                        log: log
                    )
                )
            )

            let start = ContinuousClock.now
            await model.send(.query("x")) { $0.query = "x" }?.value
            #expect(ContinuousClock.now - start >= .milliseconds(20))
            await model.expect { $0.results = ["X"] }
            await model.finish()
        }

        #expect(issues == [])
        #expect(log.entries == ["searched x"])
    }
}
