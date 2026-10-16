import Foundation
import Testing

@testable import Lattice

// The fixtures are declared at file scope, so the interactors and their effect literals are
// nonisolated, as `TestModel` requires. What ran, and in which order, is recorded in state: `interact`
// writes its `state` argument, an effect calls `modify`. Effects suspend at a sleep on an
// `EffectClock`, so the test decides when they resume. What a `ViewModel`'s teardown does to its
// effects is `ViewModelTeardownTests`'.

private let effectDuration: Duration = .seconds(1)

// MARK: - Start order

@FeatureState
struct StartOrderState: Equatable {
    var count = 0
    /// What ran, in order.
    var order: [String] = []
    /// Whether the `effects.send` that `interact` made returned a task.
    var sendDuringInteractReturnedATask: Bool?
    /// The `effects.state.count` that `interact` read.
    var effectsStateCountDuringInteract: Int?
}

enum StartOrderAction: Equatable {
    case run
    case outer
    case inner
    case outerSendingLongInner
    case longInner
    case sendDuringInteract
    case readStateDuringInteract
    case increment
}

/// The inner effect sleeps one interval and the outer effect two, so `advance` wakes them in that
/// order.
@Interactor<StartOrderState, StartOrderAction>
struct StartOrderInteractor {
    let clock: EffectClock
    var nestedTask = LockedNestedTaskBox()

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .run:
                state.order.append("interact")
                defer { state.order.append("interact defer") }
                effects.perform {
                    try effects.modify { $0.order.append("effect preamble") }
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.order.append("effect resumed") }
                }
                state.order.append("interact after perform")

            case .outer:
                state.order.append("outer interact")
                effects.perform {
                    try effects.modify { $0.order.append("outer effect 1 preamble") }
                    try effects.send(.inner)
                    try effects.modify { $0.order.append("outer effect 1 after send") }
                    try await clock.sleep(for: effectDuration * 2)
                    try effects.modify { $0.order.append("outer effect 1 resumed") }
                }
                effects.perform {
                    try effects.modify { $0.order.append("outer effect 2 preamble") }
                }

            case .inner:
                state.order.append("inner interact")
                effects.perform {
                    try effects.modify { $0.order.append("inner effect preamble") }
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.order.append("inner effect resumed") }
                }

            case .outerSendingLongInner:
                effects.perform {
                    nestedTask.task = try effects.send(.longInner)
                    await Task.yield()
                    try effects.modify { $0.order.append("outer effect finished") }
                }

            case .longInner:
                effects.perform {
                    try await clock.sleep(for: .seconds(1_000))  // never advanced: only a cancel ends it
                    try effects.modify { $0.order.append("inner effect finished") }
                }

            case .sendDuringInteract:
                state.sendDuringInteractReturnedATask = (try? effects.send(.increment)) != nil

            case .readStateDuringInteract:
                state.count += 1
                state.effectsStateCountDuringInteract = effects.state.count

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
    var clock = EffectClock()

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
                    try await clock.sleep(for: effectDuration)
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
struct ThrownErrorState: Equatable {
    /// How the request ended, recorded before the effect throws.
    var requestOutcome: String?
}

enum ThrownErrorAction {
    case request
    case cancelRequest
}

/// `.request`'s effect waits for the answer, which ends on cancellation too, and ends in a
/// `DependencyError` either way: cancelled meanwhile, it throws one in place of the answer's
/// `CancellationError`; otherwise the request fails with one.
@Interactor<ThrownErrorState, ThrownErrorAction>
struct ThrownErrorInteractor {
    @EffectID var request
    let answer: Gate

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .request:
                effects.perform(id: request) {
                    do {
                        try await answer.pass()
                    } catch {
                        try effects.modify { $0.requestOutcome = "cancelled" }
                        throw DependencyError()
                    }
                    try effects.modify { $0.requestOutcome = "failed" }
                    throw DependencyError()
                }

            case .cancelRequest:
                effects.cancel(request)
            }
        }
    }
}

// MARK: - Snapshot semantics

@FeatureState
struct FanOutState: Equatable {
    var round = 0
    var started: [String] = []
    var completed: Set<String> = []
}

enum FanOutAction {
    case fanOut
}

/// Every `.fanOut` performs two effects; in the first round, effect 1 re-sends `.fanOut` from its
/// preamble, before effect 2 has started.
@Interactor<FanOutState, FanOutAction>
struct FanOutInteractor {
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .fanOut:
                state.round += 1
                let round = state.round
                effects.perform {
                    try effects.modify { $0.started.append("round \(round) effect 1") }
                    if round == 1 {
                        try effects.send(.fanOut)
                    }
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.insert("round \(round) effect 1") }
                }
                effects.perform {
                    try effects.modify { $0.started.append("round \(round) effect 2") }
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.insert("round \(round) effect 2") }
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
    let clock: EffectClock

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

/// When `send` starts effects and what its task covers, what re-handling a case does to effects that
/// ignore cancellation, which thrown errors are reported, and the start phase's snapshot.
@Suite
struct SchedulingTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeStartOrderModel(
        clock: EffectClock,
        nestedTask: LockedNestedTaskBox = LockedNestedTaskBox(),
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestModel<Feature<StartOrderAction, StartOrderState>> {
        await TestModel(
            initialState: StartOrderState(),
            feature: Feature(interactor: StartOrderInteractor(clock: clock, nestedTask: nestedTask)),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    // MARK: Start order

    /// `send` folds the preamble's modification in: it ran before `send` returned. The rest of the
    /// effect runs only once `advance` wakes it.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func effectPreambleRunsBeforeSendReturns() async {
        let clock = EffectClock()
        let model = await makeStartOrderModel(clock: clock)

        await model.send(.run) {
            $0.order = ["interact", "interact after perform", "interact defer", "effect preamble"]
        }

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.order.append("effect resumed") }
        await model.finish()
    }

    /// `perform` only enqueues: the effect starts after `interact` (and its `defer`) returned.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func deferInInteractRunsBeforeTheEffectStarts() async {
        let clock = EffectClock()
        let model = await makeStartOrderModel(clock: clock)

        await model.send(.run) {
            $0.order = ["interact", "interact after perform", "interact defer", "effect preamble"]
        }

        await model.skipInFlightEffects()
        await model.finish()
    }

    /// The outer effect's send is handled, with the inner effect's preamble, before the outer effect
    /// carries on and before the outer send starts its second effect.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func sendFromAnEffectPreambleIsProcessedDepthFirst() async {
        let clock = EffectClock()
        let model = await makeStartOrderModel(clock: clock)

        await model.send(.outer) {  // up to the action the outer effect sent
            $0.order = ["outer interact", "outer effect 1 preamble"]
        }
        await model.receive(.inner) {
            $0.order += ["inner interact", "inner effect preamble", "outer effect 1 after send", "outer effect 2 preamble"]
        }

        await model.advance(clock, by: effectDuration * 2)
        await model.expect { $0.order += ["inner effect resumed", "outer effect 1 resumed"] }
        await model.finish()
    }

    /// A task that waited for the inner effect, which sleeps until cancelled, would stall this
    /// test: the time limit reports the stall under the test's name, and the wait is
    /// cancellation-aware so the test then ends instead of hanging the run.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func sendTaskDoesNotCoverTheEffectsOfSendsItsEffectsMake() async throws {
        let clock = EffectClock()
        let nestedTask = LockedNestedTaskBox()
        let model = await makeStartOrderModel(clock: clock, nestedTask: nestedTask)

        let outerTask = await model.send(.outerSendingLongInner)
        await withTaskCancellationHandler {
            await outerTask?.value
        } onCancel: {
            outerTask?.cancel()
        }

        // The outer effect finished; the inner effect it started through `effects.send` still sleeps.
        await model.receive(.longInner) { $0.order = ["outer effect finished"] }
        #expect(clock.sleeperCount == 1)

        let innerTask = try #require(nestedTask.task)
        innerTask.cancel()
        // The send task started immediately, so cancelling it cancelled the effect; checked before
        // the wait, so a cancel that did not arrive fails instead of hanging.
        try #require(clock.sleeperCount == 0)
        await innerTask.value
        await model.finish()  // the inner effect never finished
    }

    // MARK: Reentrancy

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func sendDuringInteractIsReportedReturnsNilAndLeavesStateUntouched() async {
        let issues = await reportedIssueDetails {
            let model = await makeStartOrderModel(clock: EffectClock())
            await model.send(.sendDuringInteract) { $0.sendDuringInteractReturnedATask = false }  // `count` stays 0
            await model.finish()
        }

        #expect(
            issues.map(\.message) == [
                "Can't send another action before handling this one; use effects.perform { try effects.send(action) }"
            ]
        )
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func effectsStateDuringInteractIsReportedAndReturnsTheCommittedPreActionValue() async {
        let issues = await reportedIssueDetails {
            let model = await makeStartOrderModel(clock: EffectClock())
            await model.send(.readStateDuringInteract) {
                $0.count = 1
                $0.effectsStateCountDuringInteract = 0
            }
            await model.finish()
        }

        #expect(issues.map(\.message) == ["Read 'effects.state' during interact; use the 'state' argument instead"])
    }

    // MARK: Cancelled effects

    /// `TestViewModel`: the 100 synchronous sends hold the main actor, where the effects run, so
    /// every send but the first re-handles the case while the previous effect is still suspended.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func reHandledCaseStillDeliversSendsOfEffectsThatIgnoreCancellation() async {
        let model = TestViewModel(
            initialState: CancelledEffectState(),
            feature: Feature(interactor: CancelledEffectInteractor())
        )

        var tasks: [Task<Void, Never>] = []
        for count in 1...100 {
            if let task = model.send(.incrementThenSendDecrement, assert: { $0.count = count }) {
                tasks.append(task)
            }
        }
        #expect(tasks.count == 100)

        for task in tasks { await task.value }
        for count in (0..<100).reversed() {
            await model.receive(.decrement) { $0.count = count }
        }
        await model.finish()
    }

    /// `TestViewModel`, as above.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func reHandledCaseStillCommitsModificationsOfEffectsThatIgnoreCancellation() async {
        let model = TestViewModel(
            initialState: CancelledEffectState(),
            feature: Feature(interactor: CancelledEffectInteractor())
        )

        var tasks: [Task<Void, Never>] = []
        for count in 1...100 {
            if let task = model.send(.incrementThenModifyDecrement, assert: { $0.count = count }) {
                tasks.append(task)
            }
        }
        #expect(tasks.count == 100)

        for task in tasks { await task.value }
        model.expect { $0.count = 0 }  // 100 decrements
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandledCaseLosesTheWorkOfEffectsCancelledAtASleep() async {
        let clock = EffectClock()
        let model = await TestModel(
            initialState: CancelledEffectState(),
            feature: Feature(interactor: CancelledEffectInteractor(clock: clock))
        )

        for count in 1...100 {
            await model.send(.incrementThenSleepThenModifyDecrement) { $0.count = count }
        }
        #expect(clock.sleeperCount == 1)  // each send cancelled the previous effect at its sleep

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.count = 99 }  // only the last effect's decrement arrived
        await model.finish()
    }

    // MARK: Thrown errors

    /// Cancellation can surface as an error other than `CancellationError`, so whatever an effect
    /// throws once its task is cancelled is not reported.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func errorThrownByACancelledEffectIsNotReported() async {
        let answer = Gate()
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: ThrownErrorState(),
                feature: Feature(interactor: ThrownErrorInteractor(answer: answer))
            )
            let task = await model.send(.request)
            await model.send(.cancelRequest)  // cancels the effect while it waits for the answer
            await task?.value
            await model.expect { $0.requestOutcome = "cancelled" }  // then it threw a `DependencyError`
            await model.finish()
        }

        #expect(issues == [])
    }

    /// The same error from an effect that was not cancelled is a failure, and is reported.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func errorThrownByALiveEffectIsReported() async {
        let answer = Gate()
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: ThrownErrorState(),
                feature: Feature(interactor: ThrownErrorInteractor(answer: answer))
            )
            let task = await model.send(.request)
            answer.open()
            await task?.value
            await model.expect { $0.requestOutcome = "failed" }
            await model.finish()
        }

        #expect(issues.map(\.message) == ["Effect threw: DependencyError()"])
    }

    // MARK: Current behaviour of the start phase

    /// The start phase iterates a snapshot of the queue, so an effect whose preamble re-sends its
    /// own case cancels the already started effects of that case (itself included) but not the
    /// effects queued after it by the outer send, which start once the nested send returns.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func preambleResendOfItsOwnCaseDoesNotCancelTheOuterSendsNotYetStartedEffects() async {
        let clock = EffectClock()
        let model = await TestModel(initialState: FanOutState(), feature: Feature(interactor: FanOutInteractor(clock: clock)))

        await model.send(.fanOut) {  // up to the action effect 1 sent from its preamble
            $0.round = 1
            $0.started = ["round 1 effect 1"]
        }
        await model.receive(.fanOut) {  // the nested round's effects, then the outer send's effect 2
            $0.round = 2
            $0.started += ["round 2 effect 1", "round 2 effect 2", "round 1 effect 2"]
        }

        await model.advance(clock, by: effectDuration)
        await model.expect {  // round 1's effect 1 never completed
            $0.completed = ["round 2 effect 1", "round 2 effect 2", "round 1 effect 2"]
        }
        await model.finish()
    }

    /// A bare `Core`: `inFlightTasks` is what the test shells wait on, and no shell shows it to an
    /// effect. An effect's task handle exists only once `Task.immediate` returns, so `inFlightTasks`
    /// omits an effect while it runs its own preamble.
    @MainActor
    @Test
    func inFlightTasksOmitsAnEffectDuringItsOwnPreamble() {
        let probe = InFlightProbe()
        let core = Core(
            isolation: MainActor.shared,
            initialState: InFlightProbeState(),
            interactor: InFlightProbeInteractor(probe: probe, clock: EffectClock()).eraseToAnyInteractor(),
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
