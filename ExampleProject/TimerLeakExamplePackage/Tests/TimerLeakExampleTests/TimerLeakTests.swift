import Lattice
import Testing

@testable import TimerLeakExample

// The tests run the ticker under `TestModel`, so the suite is not `@MainActor` and every test that
// creates one is `@available(macOS 26, *)` (the package supports macOS 14); the teardown test uses
// the app's `ViewModel` on the main actor. Time is a `GateClock`: a test waits until the ticker is
// sleeping, then moves the clock one interval, once per tick.

@Suite
struct TimerLeakTests {
    /// Every tick counts and rebuilds the child wholesale, but only every hundredth tick shows a
    /// new value: the other rebuilds are content-equal, which is the leak path the demo profiles.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func everyTickRebuildsTheChildAndEveryHundredthShowsANewValue() async {
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

    /// Releasing the view model cancels the ticker. Released on the main actor, its `isolated
    /// deinit` runs as the last reference goes, and the ticker's sleep ends inside it.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func releasingTheViewModelStopsTheTicker() async {
        let clock = GateClock()
        weak var weakViewModel: ViewModel<Feature<TimerLeakEvent, TimerLeakState>>?
        do {
            let viewModel = ViewModel(
                initialState: TimerLeakState(),
                feature: Feature(interactor: TimerLeakInteractor(clock: clock, tickInterval: tickInterval))
            )
            weakViewModel = viewModel
            viewModel.sendViewEvent(.start)
            await clock.waitForSleepers(1)
        }

        #expect(weakViewModel == nil)
        #expect(clock.pendingSleeps == [])  // cancelled by the deinit, synchronously
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
