import CasePaths
import Lattice
import Observation
import Testing

@testable import ScopedCompositionExample

// The render-boundary tests observe the reads `PhaseExampleView` and its children perform, so each
// checks which boundaries a change crosses; they run on the main actor, under `ViewModel`. The
// other tests run the feature under `TestModel`, so the suite is not `@MainActor` and each of them
// is `@available(macOS 26, *)` (the package supports macOS 14). The load and the ticker sleep on a
// `GateClock`: a test waits until they are sleeping, then moves the clock past them.

@Suite
struct PhaseExampleTests {
    // MARK: Render boundaries

    // Without state equality, the root switch still stays put: a case without a payload keeps the
    // same identity across commits, so a tick that leaves `.loading` showing is not a wholesale
    // replacement.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func tickWhileLoadingDoesNotInvalidateTheRootSwitch() async {
        let clock = GateClock()
        let viewModel = makeViewModel(clock: clock, areStatesEqual: nil)
        viewModel.sendViewEvent(.startTicking)
        let rootSwitch = observe { _ = viewModel.viewState }

        await tickOnce(clock)
        #expect(!rootSwitch.didChange)
        #expect(viewModel.viewState == .loading)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func tickWhileIdleInvalidatesNeitherSwitch() async {
        let clock = GateClock()
        let viewModel = makeViewModel(initialState: .success(SuccessState()), clock: clock)
        viewModel.sendViewEvent(.startTicking)
        let telemetry = telemetryScope(of: viewModel)
        let rootSwitch = observe { _ = viewModel.viewState }
        let innerSwitch = observe { _ = telemetry.subphase }

        await tickOnce(clock)
        #expect(!rootSwitch.didChange)
        #expect(!innerSwitch.didChange)
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func payloadEditsWhileActiveInvalidateOnlyTheirLeaf() async {
        let clock = GateClock()
        let viewModel = makeViewModel(initialState: .success(SuccessState()), clock: clock)
        viewModel.sendViewEvent(.success(.session(.telemetry(.startTapped))))
        viewModel.sendViewEvent(.startTicking)
        let success = viewModel.scope(state: \.success, action: \.success)
        let telemetry = telemetryScope(of: viewModel)
        let active = telemetry.scope(state: \.subphase, action: \.subphase)
            .scope(state: \.active, action: \.active)

        let rootSwitch = observe { _ = viewModel.viewState }
        let innerSwitch = observe { _ = telemetry.subphase }
        let summary = observe { _ = success.scope(state: \.summary, action: \.summary).count }
        let tick = observe { _ = active.tick }
        let note = observe { _ = active.note }

        await tickOnce(clock)
        #expect(tick.didChange)
        #expect(!note.didChange)
        #expect(!innerSwitch.didChange)
        #expect(!summary.didChange)
        #expect(!rootSwitch.didChange)
        #expect(active.tick == 1)

        let noteAfterTick = observe { _ = active.note }
        let tickAfterTick = observe { _ = active.tick }
        active.sendViewEvent(.noteChanged("typed"))
        #expect(noteAfterTick.didChange)
        #expect(!tickAfterTick.didChange)
        #expect(active.note == "typed")
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func caseTransitionsInvalidateExactlyTheirSwitch() async {
        let clock = GateClock()
        let viewModel = makeViewModel(clock: clock)
        let rootSwitchBeforeLoad = observe { _ = viewModel.viewState }
        let load = viewModel.sendViewEvent(.loadTapped)
        await clock.waitForSleepers(1)
        clock.moveForward(by: loadDuration)
        await load?.value
        #expect(rootSwitchBeforeLoad.didChange)

        let telemetry = telemetryScope(of: viewModel)
        let rootSwitch = observe { _ = viewModel.viewState }
        let innerSwitch = observe { _ = telemetry.subphase }
        telemetry.sendViewEvent(.startTapped)
        #expect(innerSwitch.didChange)
        #expect(!rootSwitch.didChange)

        let rootSwitchBeforeReset = observe { _ = viewModel.viewState }
        viewModel.sendViewEvent(.resetTapped)
        #expect(rootSwitchBeforeReset.didChange)
        #expect(viewModel.viewState == .loading)
    }

    // MARK: Load, ticks and payloads

    /// The load writes the success case once its delay is over. Tapping Load again auto-cancels
    /// the waiting load and starts the delay over, so the success case comes once, a full delay
    /// after the last tap.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func loadShowsTheSuccessCaseAFullDelayAfterTheLastTap() async throws {
        let clock = GateClock()
        let model = await makeModel(clock: clock)

        let firstLoad = await model.send(.loadTapped)  // nothing changes until the load is over
        await clock.waitForSleepers(1)
        clock.moveForward(by: .milliseconds(500))

        let load = await model.send(.loadTapped)  // auto-cancels the first load at its sleep
        await clock.waitForSleepers(1)
        try #require(clock.pendingSleeps == [loadDuration])  // only the second load, a full delay away
        await firstLoad?.value
        await model.expect { _ in }  // the cancelled load ended without writing anything

        clock.moveForward(by: loadDuration)
        await load?.value
        await model.expect { $0 = .success(SuccessState()) }  // the load wrote the new case
        await model.finish()
    }

    /// Only the `.active` payload counts ticks: a tick while `.idle` changes nothing, and Stop
    /// drops the count, so the next Start begins from zero. Cancelling the task `.startTicking`
    /// returned stops the ticker, which is what the root view's `.task` does when the view goes
    /// away.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func ticksCountOnlyWhileActiveUntilTheTickerIsCancelled() async {
        let clock = GateClock()
        let model = await makeModel(initialState: .success(SuccessState()), clock: clock)

        let ticker = await model.send(.startTicking)
        await tickOnce(clock)
        await model.expect { _ in }  // `.idle`: the tick changed nothing

        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }
        await tickOnce(clock)
        await tickOnce(clock)
        await model.expect {  // two modifications, one assertion
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState(tick: 2, note: "")) }
        }

        await model.send(.success(.session(.telemetry(.stopTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .idle }
        }
        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }

        ticker?.cancel()
        #expect(clock.pendingSleeps == [])  // the ticker's sleep ended inside the cancel
        await model.finish()  // the ticker ended without another tick
    }

    /// Sending `.startTicking` again, as a root view that appears again does, auto-cancels the
    /// running ticker, so there is never a second one: the next tick comes a full interval after
    /// the restart.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func startingTheTickerAgainReplacesTheRunningOne() async {
        let clock = GateClock()
        let model = await makeModel(initialState: .success(SuccessState()), clock: clock)
        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }

        await model.send(.startTicking)
        await clock.waitForSleepers(1)
        clock.moveForward(by: .milliseconds(500))  // halfway to the first tick

        let ticker = await model.send(.startTicking)  // auto-cancels the running ticker at its sleep
        await clock.waitForSleepers(1)
        #expect(clock.pendingSleeps == [tickInterval])  // only the new ticker, a full interval away

        await tickOnce(clock)
        await model.expect {  // one tick, not one per ticker
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState(tick: 1, note: "")) }
        }

        ticker?.cancel()
        await model.finish()
    }

    /// Reset and Stop drop their payload, so the next Load or Start begins from the defaults. A
    /// Load while loaded leaves the payload alone, and a send for a case that is no longer showing
    /// changes nothing.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func resetAndStopReturnToDefaultPayloadsAndLateSendsAreDropped() async {
        let clock = GateClock()
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
        let loadWhileLoaded = await model.send(.loadTapped)
        await clock.waitForSleepers(1)
        clock.moveForward(by: loadDuration)
        await loadWhileLoaded?.value
        await model.expect { _ in }  // the load found the success case and left it alone

        await model.send(.resetTapped) { $0 = .loading }
        await model.send(.success(.titleChanged("Late")))
        let load = await model.send(.loadTapped)
        await clock.waitForSleepers(1)
        clock.moveForward(by: loadDuration)
        await load?.value
        await model.expect { $0 = .success(SuccessState()) }
        await model.finish()
    }
}

/// How long the fake load takes, and the time between two ticks, in the tests.
private let loadDuration: Duration = .seconds(1)
private let tickInterval: Duration = .seconds(1)

private final class ChangeProbe: @unchecked Sendable {
    var didChange = false
}

@MainActor
private func makeViewModel(
    initialState: PhaseState = .loading,
    clock: GateClock,
    areStatesEqual: ((PhaseState, PhaseState) -> Bool)? = { $0 == $1 }
) -> PhaseExampleViewModel {
    ViewModel(
        initialState: initialState,
        feature: Feature(interactor: makeInteractor(clock: clock), areStatesEqual: areStatesEqual)
    )
}

@available(macOS 26, *)
private func makeModel(
    initialState: PhaseState = .loading,
    clock: GateClock
) async -> TestModel<Feature<PhaseEvent, PhaseState>> {
    await TestModel(initialState: initialState, feature: Feature(interactor: makeInteractor(clock: clock)))
}

private func makeInteractor(clock: GateClock) -> PhaseInteractor<GateClock> {
    PhaseInteractor(clock: clock, loadDuration: loadDuration, tickInterval: tickInterval)
}

@MainActor
private func observe(_ read: () -> Void) -> ChangeProbe {
    let probe = ChangeProbe()
    withObservationTracking(read) { probe.didChange = true }
    return probe
}

@MainActor
private func telemetryScope(
    of viewModel: PhaseExampleViewModel
) -> ScopedViewModel<TelemetryState, TelemetryAction> {
    viewModel.scope(state: \.success, action: \.success)
        .scope(state: \.session, action: \.session)
        .scope(state: \.telemetry, action: \.telemetry)
}

/// Lets the running ticker tick once: waits until it sleeps, moves the clock one interval, then
/// waits until it sleeps again, which it does only after it has committed the tick.
private func tickOnce(_ clock: GateClock) async {
    await clock.waitForSleepers(1)
    clock.moveForward(by: tickInterval)
    await clock.waitForSleepers(1)
}
