import Clocks
import Foundation
import Testing

@testable import Lattice

// MARK: - Start order

@FeatureState
struct StartOrderState: Equatable {
    var count = 0
}

enum StartOrderAction {
    case run
    case outer
    case inner
    case outerSendingLongInner
    case longInner
    case sendDuringInteract
    case readStateDuringInteract
    case increment
}

/// The task an effect got back from its own `effects.send`.
final class NestedTaskBox {
    var task: Task<Void, Never>?
}

@Interactor<StartOrderState, StartOrderAction>
struct StartOrderInteractor {
    let log: EffectLog
    let clock: TestClock<Duration>
    let nestedTask: NestedTaskBox

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .run:
                log.append("interact")
                defer { log.append("interact defer") }
                effects.perform {
                    log.append("effect preamble")
                    await Task.yield()
                    log.append("effect resumed")
                }
                log.append("interact after perform")

            case .outer:
                log.append("outer interact")
                effects.perform {
                    log.append("outer effect 1 preamble")
                    try effects.send(.inner)
                    log.append("outer effect 1 after send")
                    await Task.yield()
                    log.append("outer effect 1 resumed")
                }
                effects.perform {
                    log.append("outer effect 2 preamble")
                }

            case .inner:
                log.append("inner interact")
                effects.perform {
                    log.append("inner effect preamble")
                    await Task.yield()
                    log.append("inner effect resumed")
                }

            case .outerSendingLongInner:
                effects.perform {
                    nestedTask.task = try effects.send(.longInner)
                    await Task.yield()
                    log.append("outer effect finished")
                }

            case .longInner:
                effects.perform {
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "inner effect cancelled")
                }

            case .sendDuringInteract:
                let task = try? effects.send(.increment)
                log.append(task == nil ? "send returned nil" : "send returned a task")

            case .readStateDuringInteract:
                state.count += 1
                log.append("effects.state.count=\(effects.state.count) state.count=\(state.count)")

            case .increment:
                state.count += 1
            }
        }
    }
}

// MARK: - Cancelled effects

@FeatureState
struct CancelledEffectState: Equatable {
    var count = 0
}

enum CancelledEffectAction {
    case incrementThenSendDecrement
    case incrementThenModifyDecrement
    case incrementThenSleepThenModifyDecrement
    case decrement
}

@Interactor<CancelledEffectState, CancelledEffectAction>
struct CancelledEffectInteractor {
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .incrementThenSendDecrement:
                state.count += 1
                // `Task.yield()` ignores cancellation: an auto-cancelled effect still gets here.
                effects.perform {
                    await Task.yield()
                    try effects.send(.decrement)
                }

            case .incrementThenModifyDecrement:
                state.count += 1
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.count -= 1 }
                }

            case .incrementThenSleepThenModifyDecrement:
                state.count += 1
                // A sleep is cancellation-aware: an auto-cancelled effect throws here.
                effects.perform {
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "sleep cancelled")
                    try effects.modify { $0.count -= 1 }
                }

            case .decrement:
                state.count -= 1
            }
        }
    }
}

// MARK: - Thrown errors

/// A dependency's own error. Some dependencies surface cancellation as one rather than as
/// `CancellationError`: URLSession throws `URLError(.cancelled)`.
struct DependencyError: Error {}

@FeatureState
struct ThrownErrorState: Equatable {}

enum ThrownErrorAction {
    case request
    case cancelRequest
}

/// `.request`'s effect waits at a cancellation-aware gate and ends in a `DependencyError` either
/// way: cancelled meanwhile, it throws one in place of the gate's `CancellationError`; otherwise
/// the request fails with one.
@Interactor<ThrownErrorState, ThrownErrorAction>
struct ThrownErrorInteractor {
    @EffectID var request
    let log: EffectLog
    let gate: EffectGate

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .request:
                effects.perform(id: request) {
                    do {
                        try await gate.pass()
                    } catch {
                        log.append("request cancelled")
                        throw DependencyError()
                    }
                    log.append("request failed")
                    throw DependencyError()
                }

            case .cancelRequest:
                effects.cancel(request)
            }
        }
    }
}

// MARK: - Teardown

@FeatureState
struct TeardownState: Equatable {
    var count = 0
}

enum TeardownAction {
    case sleepThenSendAndModify
    case incrementReadThenSleepThenReadState
    case ping
}

@Interactor<TeardownState, TeardownAction>
struct TeardownInteractor {
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .sleepThenSendAndModify:
                effects.perform {
                    try? await log.sleepUntilCancelled(on: clock, appendingOnCancel: "sleep cancelled")
                    do { try effects.send(.ping) } catch { log.append("send threw \(type(of: error))") }
                    do { try effects.modify { $0.count = -1 } } catch { log.append("modify threw \(type(of: error))") }
                }

            case .incrementReadThenSleepThenReadState:
                effects.perform {
                    try effects.modify { $0.count += 1 }
                    _ = effects.state  // a successful read refreshes the last known value
                    try? await log.sleepUntilCancelled(on: clock, appendingOnCancel: "sleep cancelled")
                    log.append("effects.state.count=\(effects.state.count)")
                }

            case .ping:
                break
            }
        }
    }
}

// MARK: - Snapshot semantics

@FeatureState
struct FanOutState: Equatable {
    var round = 0
}

enum FanOutAction {
    case fanOut
}

/// Every `.fanOut` performs two effects; in the first round, effect 1 re-sends `.fanOut` from its
/// preamble, before effect 2 has started.
@Interactor<FanOutState, FanOutAction>
struct FanOutInteractor {
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .fanOut:
                state.round += 1
                let round = state.round
                effects.perform {
                    log.append("round \(round) effect 1 started")
                    if round == 1 {
                        try effects.send(.fanOut)
                    }
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "round \(round) effect 1 cancelled")
                }
                effects.perform {
                    log.append("round \(round) effect 2 started")
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "round \(round) effect 2 cancelled")
                }
            }
        }
    }
}

// MARK: - In-flight tasks

@FeatureState
struct InFlightProbeState: Equatable {
    var count = 0
}

enum InFlightProbeAction {
    case first
    case second
}

/// What effects saw of `Core.inFlightTasks` from their own preambles.
final class InFlightProbe {
    weak var core: Core<InFlightProbeState, InFlightProbeAction>?
    var countsSeenInPreambles: [Int] = []
}

@Interactor<InFlightProbeState, InFlightProbeAction>
struct InFlightProbeInteractor {
    let probe: InFlightProbe
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interact { _, _, effects in
            effects.perform {
                probe.countsSeenInPreambles.append(probe.core?.inFlightTasks.count ?? -1)
                try await clock.sleep(for: .seconds(100))
            }
        }
    }
}

// MARK: - Tests

@MainActor
@Suite
struct SchedulingTests {
    private func makeStartOrderViewModel(
        log: EffectLog,
        clock: TestClock<Duration> = TestClock(),
        nestedTask: NestedTaskBox = NestedTaskBox()
    ) -> ViewModel<Feature<StartOrderAction, StartOrderState>> {
        ViewModel(
            initialState: StartOrderState(),
            feature: Feature(interactor: StartOrderInteractor(log: log, clock: clock, nestedTask: nestedTask))
        )
    }

    // MARK: Start order

    @Test
    func effectPreambleRunsBeforeSendViewEventReturns() async {
        let log = EffectLog()
        let viewModel = makeStartOrderViewModel(log: log)

        let task = viewModel.sendViewEvent(.run)
        #expect(log.entries.last == "effect preamble")
        #expect(!log.entries.contains("effect resumed"))

        await task?.value
        #expect(log.entries.last == "effect resumed")
    }

    @Test
    func deferInInteractRunsBeforeTheEffectStarts() {
        let log = EffectLog()
        let viewModel = makeStartOrderViewModel(log: log)

        viewModel.sendViewEvent(.run)

        // `perform` only enqueues: the effect starts after `interact` (and its `defer`) returned.
        #expect(log.entries == ["interact", "interact after perform", "interact defer", "effect preamble"])
    }

    @Test
    func sendFromAnEffectPreambleIsProcessedDepthFirst() async {
        let log = EffectLog()
        let viewModel = makeStartOrderViewModel(log: log)

        let task = viewModel.sendViewEvent(.outer)
        #expect(
            log.entries == [
                "outer interact",
                "outer effect 1 preamble",
                "inner interact",
                "inner effect preamble",
                "outer effect 1 after send",
                "outer effect 2 preamble",
            ]
        )

        await task?.value
        #expect(log.entries.contains("outer effect 1 resumed"))
    }

    /// A task that waited for the inner effect, which sleeps until cancelled, would stall this
    /// test: the time limit reports the stall under the test's name, and the wait is
    /// cancellation-aware so the test then ends instead of hanging the run.
    @Test(.timeLimit(.minutes(1)))
    func sendTaskDoesNotCoverTheEffectsOfSendsItsEffectsMake() async throws {
        let log = EffectLog()
        let nestedTask = NestedTaskBox()
        let viewModel = makeStartOrderViewModel(log: log, nestedTask: nestedTask)

        let outerTask = viewModel.sendViewEvent(.outerSendingLongInner)
        await withTaskCancellationHandler {
            await outerTask?.value
        } onCancel: {
            outerTask?.cancel()
        }

        // The outer effect finished; the inner effect it started through `effects.send` still sleeps.
        #expect(log.entries == ["outer effect finished"])

        let innerTask = try #require(nestedTask.task)
        innerTask.cancel()
        if #available(iOS 26, macOS 26, watchOS 26, *) {
            // The send task started immediately, so cancelling it cancelled the effect; checked
            // before the wait, so a cancel that did not arrive fails instead of hanging.
            try #require(log.entries == ["outer effect finished", "inner effect cancelled"])
        }
        await innerTask.value
        #expect(log.entries == ["outer effect finished", "inner effect cancelled"])
    }

    // MARK: Reentrancy

    @Test
    func sendDuringInteractIsReportedReturnsNilAndLeavesStateUntouched() async {
        let log = EffectLog()
        let viewModel = makeStartOrderViewModel(log: log)

        let issues = await reportedIssues {
            viewModel.sendViewEvent(.sendDuringInteract)
        }

        #expect(
            issues == [
                "Can't send another action before handling this one; use effects.perform { try effects.send(action) }"
            ]
        )
        #expect(log.entries == ["send returned nil"])
        #expect(viewModel.count == 0)
    }

    @Test
    func effectsStateDuringInteractIsReportedAndReturnsTheCommittedPreActionValue() async {
        let log = EffectLog()
        let viewModel = makeStartOrderViewModel(log: log)

        let issues = await reportedIssues {
            viewModel.sendViewEvent(.readStateDuringInteract)
        }

        #expect(issues == ["Read 'effects.state' during interact; use the 'state' argument instead"])
        #expect(log.entries == ["effects.state.count=0 state.count=1"])
        #expect(viewModel.count == 1)
    }

    // MARK: Cancelled effects

    @Test
    func reHandledCaseStillDeliversSendsOfEffectsThatIgnoreCancellation() async {
        let viewModel = ViewModel(
            initialState: CancelledEffectState(),
            feature: Feature(interactor: CancelledEffectInteractor(log: EffectLog(), clock: TestClock()))
        )

        let tasks = (0..<100).compactMap { _ in viewModel.sendViewEvent(.incrementThenSendDecrement) }
        #expect(tasks.count == 100)
        #expect(viewModel.count == 100)

        for task in tasks { await task.value }
        #expect(viewModel.count == 0)
    }

    @Test
    func reHandledCaseStillCommitsModificationsOfEffectsThatIgnoreCancellation() async {
        let viewModel = ViewModel(
            initialState: CancelledEffectState(),
            feature: Feature(interactor: CancelledEffectInteractor(log: EffectLog(), clock: TestClock()))
        )

        let tasks = (0..<100).compactMap { _ in viewModel.sendViewEvent(.incrementThenModifyDecrement) }
        #expect(tasks.count == 100)
        #expect(viewModel.count == 100)

        for task in tasks { await task.value }
        #expect(viewModel.count == 0)
    }

    @Test
    func reHandledCaseLosesTheWorkOfEffectsCancelledAtASleep() async throws {
        let log = EffectLog()
        let viewModel = ViewModel(
            initialState: CancelledEffectState(),
            feature: Feature(interactor: CancelledEffectInteractor(log: log, clock: TestClock()))
        )

        let tasks = (0..<100).compactMap { _ in viewModel.sendViewEvent(.incrementThenSleepThenModifyDecrement) }
        #expect(tasks.count == 100)

        // Each send auto-cancelled the previous effect; the last one still sleeps.
        try #require(log.entries == Array(repeating: "sleep cancelled", count: 99))
        for task in tasks.dropLast() { await task.value }

        // The cancelled effects threw at their sleep: none of their decrements arrived.
        #expect(viewModel.count == 100)
    }

    // MARK: Thrown errors

    /// Cancellation can surface as an error other than `CancellationError`, so whatever an effect
    /// throws once its task is cancelled is not reported.
    @Test(.timeLimit(.minutes(1)))
    func errorThrownByACancelledEffectIsNotReported() async {
        let log = EffectLog()
        let gate = EffectGate()
        let viewModel = ViewModel(
            initialState: ThrownErrorState(),
            feature: Feature(interactor: ThrownErrorInteractor(log: log, gate: gate))
        )

        let issues = await reportedIssues {
            let task = viewModel.sendViewEvent(.request)
            viewModel.sendViewEvent(.cancelRequest)  // cancels the effect while it waits at the gate
            gate.open()
            await task?.value
        }

        #expect(log.entries == ["request cancelled"])  // it threw a `DependencyError` while cancelled
        #expect(issues == [])
    }

    /// The same error from an effect that was not cancelled is a failure, and is reported.
    @Test(.timeLimit(.minutes(1)))
    func errorThrownByALiveEffectIsReported() async {
        let log = EffectLog()
        let gate = EffectGate()
        let viewModel = ViewModel(
            initialState: ThrownErrorState(),
            feature: Feature(interactor: ThrownErrorInteractor(log: log, gate: gate))
        )

        let issues = await reportedIssues {
            let task = viewModel.sendViewEvent(.request)
            gate.open()
            await task?.value
        }

        #expect(log.entries == ["request failed"])
        #expect(issues == ["Effect threw: DependencyError()"])
    }

    // MARK: Teardown

    @Test
    func deinitCancelsEffectsAndTheirLaterSendAndModifyThrowWithoutAnIssue() async throws {
        let log = EffectLog()
        weak var weakViewModel: ViewModel<Feature<TeardownAction, TeardownState>>?
        var task: Task<Void, Never>?
        do {
            let viewModel = ViewModel(
                initialState: TeardownState(),
                feature: Feature(interactor: TeardownInteractor(log: log, clock: TestClock()))
            )
            weakViewModel = viewModel
            task = viewModel.sendViewEvent(.sleepThenSendAndModify)
        }
        #expect(weakViewModel == nil)
        try #require(log.entries == ["sleep cancelled"])  // by the deinit, synchronously

        await task?.value

        #expect(log.entries == ["sleep cancelled", "send threw CancellationError", "modify threw CancellationError"])
    }

    /// Effect tasks hold the runtime weakly, so it ends with its view model: a read after that is
    /// reported and returns the last value the effect read.
    @Test
    func effectsStateAfterDeinitIsReportedAndReturnsTheLastKnownValue() async {
        let log = EffectLog()
        let issues = await reportedIssues {
            var task: Task<Void, Never>?
            do {
                let viewModel = ViewModel(
                    initialState: TeardownState(count: 7),
                    feature: Feature(interactor: TeardownInteractor(log: log, clock: TestClock()))
                )
                task = viewModel.sendViewEvent(.incrementReadThenSleepThenReadState)
            }
            guard log.entries == ["sleep cancelled"] else { return }  // not cancelled: do not wait forever
            await task?.value
        }

        #expect(issues == ["Read 'effects.state' after the model was invalidated or the scoped state went away"])
        // 8, not the initial 7: the value of the effect's last successful read.
        #expect(log.entries == ["sleep cancelled", "effects.state.count=8"])
    }

    // MARK: Current behaviour of the start phase

    /// The start phase iterates a snapshot of the queue, so an effect whose preamble re-sends its
    /// own case cancels the already started effects of that case (itself included) but not the
    /// effects queued after it by the outer send, which start once the nested send returns.
    @Test
    func preambleResendOfItsOwnCaseDoesNotCancelTheOuterSendsNotYetStartedEffects() {
        let log = EffectLog()
        let viewModel = ViewModel(
            initialState: FanOutState(),
            feature: Feature(interactor: FanOutInteractor(log: log, clock: TestClock()))
        )

        viewModel.sendViewEvent(.fanOut)

        #expect(
            log.entries == [
                "round 1 effect 1 started",
                "round 2 effect 1 started",
                "round 2 effect 2 started",
                "round 1 effect 1 cancelled",
                "round 1 effect 2 started",
            ]
        )
        #expect(viewModel.round == 2)
    }

    /// An effect's task handle exists only once `Task.immediate` returns, so `inFlightTasks` omits
    /// an effect while it runs its own preamble.
    @Test
    func inFlightTasksOmitsAnEffectDuringItsOwnPreamble() {
        let probe = InFlightProbe()
        let core = Core(
            isolation: MainActor.shared,
            initialState: InFlightProbeState(),
            interactor: InFlightProbeInteractor(probe: probe, clock: TestClock()).eraseToAnyInteractor(),
            areStatesEqual: nil
        )
        probe.core = core

        core.send(.first)
        #expect(probe.countsSeenInPreambles == [0])
        #expect(core.inFlightTasks.count == 1)

        core.send(.second)
        #expect(probe.countsSeenInPreambles == [0, 1])
        #expect(core.inFlightTasks.count == 2)

        core.invalidate()  // cancels both effects
    }
}
