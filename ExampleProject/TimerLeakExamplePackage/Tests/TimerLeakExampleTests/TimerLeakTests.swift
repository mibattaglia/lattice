import Lattice
import Testing

@testable import TimerLeakExample

// The suite runs the ticker under `TestModel`, so each test is `@available(macOS 26, *)`: the
// package supports macOS 14. Time is a `GateClock`: a test waits until the ticker is sleeping,
// then moves the clock one interval, once per tick.

@Suite
struct TimerLeakTests {
    /// Every tick counts, and only every hundredth tick shows a new value. Each tick also rebuilds
    /// the child wholesale, but a content-equal rebuild leaves no trace in state (the current child,
    /// its `_$id` and its registrars are kept), so only profiling, the resident-memory overlay,
    /// shows those rebuilds.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func everyTickCountsAndEveryHundredthShowsANewValue() async {
        let clock = GateClock()
        let model = await makeModel(clock: clock)

        let ticker = await model.send(.start)  // nothing changes until the clock moves
        await letTheTickerTick(99, on: clock)
        await model.expect { $0.tickCount = 99 }  // 99 modifications, one assertion; still "value-0"

        await letTheTickerTick(1, on: clock)
        await model.expect {
            $0.tickCount = 100
            $0.displayedValue = "value-1"
            $0.child = TimerChildState(value: "value-1")
        }

        ticker?.cancel()
        await model.finish()
    }

    /// Sending `.start` again, as a view that appears again does, auto-cancels the running ticker
    /// and starts a new one, so there is never more than one: the next tick comes a full interval
    /// after the restart, and the count goes on.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func startingAgainReplacesTheRunningTicker() async {
        let clock = GateClock()
        let model = await makeModel(clock: clock)

        await model.send(.start)
        await letTheTickerTick(1, on: clock)
        await model.expect { $0.tickCount = 1 }
        clock.moveForward(by: .milliseconds(10))  // halfway to the next tick

        let ticker = await model.send(.start)  // auto-cancels the running ticker at its sleep
        await clock.waitForSleepers(1)
        #expect(clock.pendingSleeps == [tickInterval])  // only the new ticker, a full interval away

        await letTheTickerTick(1, on: clock)
        await model.expect { $0.tickCount = 2 }  // one tick, not one per ticker

        ticker?.cancel()
        await model.finish()
    }

    /// Cancelling the task `.start` returned stops the ticker. The view's `.task` does this when
    /// the view goes away.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func cancellingTheStartTaskStopsTheTicker() async {
        let clock = GateClock()
        let model = await makeModel(clock: clock)

        let ticker = await model.send(.start)
        await clock.waitForSleepers(1)
        ticker?.cancel()
        #expect(clock.pendingSleeps == [])  // the ticker's sleep ended inside the cancel
        await model.finish()  // the ticker ended without a tick
    }

    /// Releasing the model stops the ticker, as releasing the app's view model does: the model's
    /// `isolated deinit` cancels its effects, which ends the ticker's sleep.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func releasingTheModelStopsTheTicker() async {
        let clock = GateClock()
        weak var weakModel: TestModel<Feature<TimerLeakEvent, TimerLeakState>>?
        do {
            // Exhaustive, with no `finish()`: it would wait for the ticker, which only the release
            // stops. The deinit reports only commits no assertion described, and the ticker makes
            // none while the clock stands still, so the release leaves no warning.
            let model = await makeModel(clock: clock)
            weakModel = model
            await model.send(.start)
            await clock.waitForSleepers(1)
        }

        #expect(weakModel == nil)
        await waitUntilNothingSleeps(on: clock)
        #expect(clock.pendingSleeps == [])  // the deinit cancelled the ticker, which ended its sleep
    }
}

/// The interval the tests tick at.
private let tickInterval: Duration = .milliseconds(20)

@available(macOS 26, *)
private func makeModel(clock: GateClock) async -> TestModel<Feature<TimerLeakEvent, TimerLeakState>> {
    await TestModel(
        initialState: TimerLeakState(),
        feature: Feature(interactor: TimerLeakInteractor(clock: clock, tickInterval: tickInterval))
    )
}

/// Lets the running ticker tick `count` times, with one wait and one move per tick: waits until it
/// sleeps, then moves the clock one interval. Returns once it sleeps again, which it does only after
/// it has committed the last tick.
private func letTheTickerTick(_ count: Int, on clock: GateClock) async {
    for _ in 0..<count {
        await clock.waitForSleepers(1)
        clock.moveForward(by: tickInterval)
    }
    await clock.waitForSleepers(1)
}

/// Waits until no sleep is live on `clock`. A released model's `isolated deinit` runs on the model's
/// own actor after the release returns, so the cancel it makes is not synchronous with the test
/// task. The test's time limit cancels a wait for a sleep that never ends.
private func waitUntilNothingSleeps(on clock: GateClock) async {
    while !clock.pendingSleeps.isEmpty, !Task.isCancelled {
        await Task.yield()
    }
}
