import Lattice
import Testing

@testable import TimerLeakExample

// The suite runs the ticker under `TestModel`. Time is an `EffectClock`: the ticker is asleep on it
// when `.start`'s `send` returns, and `model.advance` lets it tick once per interval the clock
// moves.

@Suite
struct TimerLeakTests {
    /// Every tick counts, and only every hundredth tick shows a new value. Each tick also rebuilds
    /// the child wholesale, but a content-equal rebuild leaves no trace in state (the current child,
    /// its `_$id` and its registrars are kept), so only profiling, the resident-memory overlay,
    /// shows those rebuilds.
    @Test(.timeLimit(.minutes(1)))
    func everyTickCountsAndEveryHundredthShowsANewValue() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        let ticker = await model.send(.start)  // nothing changes until the clock moves
        await model.advance(clock, by: tickInterval * 99)
        await model.expect { $0.tickCount = 99 }  // 99 modifications, one assertion; still "value-0"

        await model.advance(clock, by: tickInterval)
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
    @Test(.timeLimit(.minutes(1)))
    func startingAgainReplacesTheRunningTicker() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.start)
        await model.advance(clock, by: tickInterval)
        await model.expect { $0.tickCount = 1 }
        await model.advance(clock, by: .milliseconds(10))  // halfway to the next tick

        let ticker = await model.send(.start)  // auto-cancels the running ticker at its sleep
        await model.advance(clock, by: .milliseconds(10))  // when the replaced ticker was due
        await model.expect { _ in }  // nothing ticked: the new ticker is a full interval away

        await model.advance(clock, by: .milliseconds(10))
        await model.expect { $0.tickCount = 2 }  // one tick, not one per ticker

        ticker?.cancel()
        await model.finish()
    }

    /// Cancelling the task `.start` returned stops the ticker. The view's `.task` does this when
    /// the view goes away.
    @Test(.timeLimit(.minutes(1)))
    func cancellingTheStartTaskStopsTheTicker() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        let ticker = await model.send(.start)
        ticker?.cancel()
        await model.advance(clock, by: tickInterval)  // when the first tick was due
        await model.expect { _ in }  // the cancelled ticker did not tick
        await model.finish()  // the ticker ended without a tick
    }

    /// Releasing the model while the ticker runs deallocates it, as releasing the app's view model
    /// does: the running ticker does not keep the model alive. That the deinit then cancels the
    /// ticker is proven in Lattice's own tests, by
    /// `SchedulingTests.deinitCancelsEffectsAndTheirLaterSendAndModifyThrowWithoutAnIssue`.
    @Test(.timeLimit(.minutes(1)))
    func releasingTheModelWhileTheTickerRunsDeallocatesIt() async {
        let clock = EffectClock()
        weak var weakModel: TestModel<Feature<TimerLeakEvent, TimerLeakState>>?
        do {
            // Exhaustive, with no `finish()`: it would wait for the ticker, which only the release
            // stops. The deinit reports only commits no assertion described, and the ticker makes
            // none while the clock stands still, so the release leaves no warning.
            let model = await makeModel(clock: clock)
            weakModel = model
            await model.send(.start)
        }

        #expect(weakModel == nil)
    }
}

/// The interval the tests tick at.
private let tickInterval: Duration = .milliseconds(20)

private func makeModel(clock: EffectClock) async -> TestModel<Feature<TimerLeakEvent, TimerLeakState>> {
    await TestModel(
        initialState: TimerLeakState(),
        feature: Feature(interactor: TimerLeakInteractor(clock: clock, tickInterval: tickInterval))
    )
}
