import CasePaths
import Lattice
import Testing

@testable import ScopedCompositionExample

// The suite runs the feature under `TestModel`. The load and the ticker sleep on an `EffectClock`:
// they are asleep on it when their `send` returns, and `model.advance` moves the clock past them and
// lets them run.

@Suite
struct PhaseExampleTests {
    /// The load writes the success case once its delay is over. Tapping Load again auto-cancels
    /// the waiting load and starts the delay over, so the success case comes once, a full delay
    /// after the last tap.
    @Test
    func loadShowsTheSuccessCaseAFullDelayAfterTheLastTap() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.loadTapped)  // nothing changes until the load is over
        await model.advance(clock, by: .milliseconds(500))

        await model.send(.loadTapped)  // auto-cancels the first load at its sleep
        await model.advance(clock, by: .milliseconds(500))  // when the first load was due
        await model.expect { _ in }  // the cancelled load wrote nothing; the second is still asleep

        await model.advance(clock, by: .milliseconds(500))  // a full delay after the last tap
        await model.expect { $0 = .success(SuccessState()) }  // the load wrote the new case
        await model.finish()
    }

    /// The root view starts the ticker as it appears, while `.loading` is showing: a tick then
    /// changes nothing, since only the `.active` payload counts ticks.
    @Test
    func ticksWhileLoadingChangeNothing() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        let ticker = await model.send(.startTicking)
        await model.advance(clock, by: tickInterval)
        await model.expect { _ in }  // `.loading`: the tick changed nothing

        ticker?.cancel()
        await model.finish()
    }

    /// Only the `.active` payload counts ticks: a tick while `.idle` changes nothing, typing a note
    /// keeps the count, and Stop drops both, so the next Start begins from the defaults.
    /// Cancelling the task `.startTicking` returned stops the ticker, which is what the root view's
    /// `.task` does when the view goes away.
    @Test
    func ticksCountOnlyWhileActiveUntilTheTickerIsCancelled() async {
        let clock = EffectClock()
        let model = await makeModel(initialState: .success(SuccessState()), clock: clock)

        let ticker = await model.send(.startTicking)
        await model.advance(clock, by: tickInterval)
        await model.expect { _ in }  // `.idle`: the tick changed nothing

        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }
        await model.advance(clock, by: tickInterval * 2)
        await model.expect {  // two modifications, one assertion
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState(tick: 2, note: "")) }
        }
        await model.send(.success(.session(.telemetry(.subphase(.active(.noteChanged("typed"))))))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState(tick: 2, note: "typed")) }
        }

        await model.send(.success(.session(.telemetry(.stopTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .idle }
        }
        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }

        ticker?.cancel()
        await model.advance(clock, by: tickInterval)  // when the next tick was due
        await model.expect { _ in }  // the cancelled ticker did not tick
        await model.finish()  // the ticker ended without another tick
    }

    /// Sending `.startTicking` again, as a root view that appears again does, auto-cancels the
    /// running ticker, so there is never a second one: the next tick comes a full interval after
    /// the restart.
    @Test
    func startingTheTickerAgainReplacesTheRunningOne() async {
        let clock = EffectClock()
        let model = await makeModel(initialState: .success(SuccessState()), clock: clock)
        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }

        await model.send(.startTicking)
        await model.advance(clock, by: .milliseconds(500))  // halfway to the first tick

        let ticker = await model.send(.startTicking)  // auto-cancels the running ticker at its sleep
        await model.advance(clock, by: .milliseconds(500))  // when the replaced ticker was due
        await model.expect { _ in }  // nothing ticked: the new ticker is a full interval away

        await model.advance(clock, by: .milliseconds(500))
        await model.expect {  // one tick, not one per ticker
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState(tick: 1, note: "")) }
        }

        ticker?.cancel()
        await model.finish()
    }

    /// Reset and Stop drop their payload, so the next Load or Start begins from the defaults. A
    /// Load while loaded leaves the payload alone, and a send for a case that is no longer showing
    /// changes nothing.
    @Test
    func resetAndStopReturnToDefaultPayloadsAndLateSendsAreDropped() async {
        let clock = EffectClock()
        let model = await makeModel(initialState: .success(SuccessState()), clock: clock)

        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }
        await model.send(.success(.session(.telemetry(.subphase(.active(.noteChanged("typed"))))))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState(tick: 0, note: "typed")) }
        }
        await model.send(.success(.session(.telemetry(.stopTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .idle }
        }
        await model.send(.success(.session(.telemetry(.subphase(.active(.noteChanged("late")))))))
        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }

        await model.send(.success(.titleChanged("Renamed"))) {
            $0.modify(\.success) { $0.title = "Renamed" }
        }
        await model.send(.loadTapped)
        await model.advance(clock, by: loadDuration)
        await model.expect { _ in }  // the load found the success case and left it alone

        await model.send(.resetTapped) { $0 = .loading }
        await model.send(.success(.titleChanged("Late")))
        await model.send(.loadTapped)
        await model.advance(clock, by: loadDuration)
        await model.expect { $0 = .success(SuccessState()) }
        await model.finish()
    }
}

/// How long the fake load takes, and the time between two ticks, in the tests.
private let loadDuration: Duration = .seconds(1)
private let tickInterval: Duration = .seconds(1)

private func makeModel(
    initialState: PhaseState = .loading,
    clock: EffectClock
) async -> TestModel<Feature<PhaseEvent, PhaseState>> {
    await TestModel(initialState: initialState, feature: Feature(interactor: makeInteractor(clock: clock)))
}

private func makeInteractor(clock: EffectClock) -> PhaseInteractor<EffectClock> {
    PhaseInteractor(clock: clock, loadDuration: loadDuration, tickInterval: tickInterval)
}
