import Foundation
import Testing

@testable import Lattice

// Every fixture is declared at file scope, so the interactors and their effect literals are
// nonisolated, as `ActorModel` requires. The tests are nonisolated too and observe effects through
// `send(…)?.value` and the model's state, where the fixtures record what ran and in which order: an
// effect may resume on the model's executor as soon as a model call returns, so the state is read
// right after a call only when every effect that could still change it waits for an answer the
// test has not opened, or sleeps on a clock nothing advances, which only cancellation ends.

// MARK: - Start order and modifications

@FeatureState
struct ActorModelOrderState: Equatable, Sendable {
    var count = 0
    /// What ran, in order: `interact` appends to `state`, effects through `modify`.
    var order: [String] = []
}

enum ActorModelOrderAction: Equatable, Sendable {
    case run
    case outer
    case inner
    case outerSendingLongInner
    case longInner
    case modifyInPreamble
    case modifyAfterAnswer
}

@Interactor<ActorModelOrderState, ActorModelOrderAction>
struct ActorModelOrderInteractor {
    /// The answer of a slow dependency: the effects that wait for it resume when the test opens it.
    let answer: Gate
    /// Never advanced: a sleep on it ends only when it is cancelled.
    let clock: EffectClock
    let nestedTask: LockedNestedTaskBox

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .run:
                state.order.append("interact")
                defer { state.order.append("interact defer") }
                effects.perform {
                    try effects.modify { $0.order.append("effect preamble") }
                    await answer.wait()
                    try effects.modify { $0.order.append("effect resumed") }
                }
                state.order.append("interact after perform")

            case .outer:
                state.order.append("outer interact")
                effects.perform {
                    try effects.modify { $0.order.append("outer effect 1 preamble") }
                    nestedTask.task = try effects.send(.inner)
                    try effects.modify { $0.order.append("outer effect 1 after send") }
                    await answer.wait()
                    try effects.modify { $0.order.append("outer effect 1 resumed") }
                }
                effects.perform {
                    try effects.modify { $0.order.append("outer effect 2 preamble") }
                }

            case .inner:
                state.order.append("inner interact")
                effects.perform {
                    try effects.modify { $0.order.append("inner effect preamble") }
                    await answer.wait()
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
                    try await clock.sleep(for: .seconds(1_000))
                    try effects.modify { $0.order.append("inner effect finished") }
                }

            case .modifyInPreamble:
                state.count += 1
                effects.perform { try effects.modify { $0.count += 10 } }

            case .modifyAfterAnswer:
                effects.perform {
                    await answer.wait()
                    try effects.modify { $0.count = 5 }
                }
            }
        }
    }
}

// MARK: - Cancelled effects

@FeatureState
struct ActorModelCounterState: Equatable, Sendable {
    var count = 0
    /// The effects that were cancelled by the time they resumed.
    var cancelledEffects = 0
}

enum ActorModelCounterAction: Equatable, Sendable {
    case incrementThenSendDecrement
    case incrementThenModifyDecrement
    case incrementThenSleepThenModifyDecrement
    case decrement
}

@Interactor<ActorModelCounterState, ActorModelCounterAction>
struct ActorModelCounterInteractor {
    /// Never advanced: a sleep on it ends only when it is cancelled.
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .incrementThenSendDecrement:
                state.count += 1
                // `Task.yield()` ignores cancellation: an auto-cancelled effect still gets here.
                effects.perform {
                    await Task.yield()
                    if Task.isCancelled {
                        try effects.modify { $0.cancelledEffects += 1 }
                    }
                    try effects.send(.decrement)
                }

            case .incrementThenModifyDecrement:
                state.count += 1
                effects.perform {
                    await Task.yield()
                    if Task.isCancelled {
                        try effects.modify { $0.cancelledEffects += 1 }
                    }
                    try effects.modify { $0.count -= 1 }
                }

            case .incrementThenSleepThenModifyDecrement:
                state.count += 1
                // A sleep is cancellation-aware: an auto-cancelled effect throws here.
                effects.perform {
                    try await clock.sleep(for: .seconds(1_000))
                    try effects.modify { $0.count -= 1 }
                }

            case .decrement:
                state.count -= 1
            }
        }
    }
}

// MARK: - Teardown

@FeatureState
struct ActorModelTeardownState: Equatable, Sendable {
    var count = 0
}

enum ActorModelTeardownAction: Equatable, Sendable {
    case sleepThenSendAndModify
    case ping
}

/// The effect sleeps on a clock nothing advances, so only teardown ends the sleep, which it signals
/// on `cancelled`. What its calls throw after that, when it may no longer write state, goes to the
/// log.
@Interactor<ActorModelTeardownState, ActorModelTeardownAction>
struct ActorModelTeardownInteractor {
    let log: EffectLog
    let clock: EffectClock
    let cancelled: AsyncStream<Void>.Continuation

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .sleepThenSendAndModify:
                effects.perform {
                    try? await withTaskCancellationHandler {
                        try await clock.sleep(for: .seconds(1_000))
                    } onCancel: {
                        cancelled.yield()
                    }
                    do { try effects.send(.ping) } catch { log.append("send threw \(type(of: error))") }
                    do { try effects.modify { $0.count = -1 } } catch { log.append("modify threw \(type(of: error))") }
                }

            case .ping:
                break
            }
        }
    }
}

// MARK: - One job on the model's executor

// Each helper is isolated to the model and never suspends, so it runs as one job on the model's
// executor: no effect job queued there runs before it returns. A read through a later model call
// would come after such jobs and could not tell an effect that ran inside `send` from one that ran
// right after it.

/// Sends `action` and reads the state that `send` committed.
@available(iOS 26, macOS 26, watchOS 26, *)
private func sendThenReadState(
    _ action: ActorModelOrderAction,
    on model: isolated ActorModel<Feature<ActorModelOrderAction, ActorModelOrderState>>
) -> (task: Task<Void, Never>?, state: ActorModelOrderState) {
    let task = model.send(action)
    return (task, model.state)
}

/// Sends `action` `times` times, then reads the count. No effect resumes in between, so every send
/// after the first re-handles the case while the previous effect is still suspended.
@available(iOS 26, macOS 26, watchOS 26, *)
private func sendInOneJob(
    _ action: ActorModelCounterAction,
    times: Int,
    on model: isolated ActorModel<Feature<ActorModelCounterAction, ActorModelCounterState>>
) -> (tasks: [Task<Void, Never>], count: Int) {
    var tasks: [Task<Void, Never>] = []
    for _ in 0..<times {
        if let task = model.send(action) {
            tasks.append(task)
        }
    }
    return (tasks, model.state.count)
}

// MARK: - Tests

/// The §6 scheduling guarantees under `ActorModel`: what `send` has done when it returns, what its
/// task covers, what re-handling a case does to effects that ignore cancellation, when effects'
/// modifications are committed, and what deallocating the model does to a sleeping effect.
@Suite
struct ActorModelSchedulingTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeOrderModel(
        answer: Gate = Gate(),
        clock: EffectClock = EffectClock(),
        nestedTask: LockedNestedTaskBox = LockedNestedTaskBox()
    ) async -> ActorModel<Feature<ActorModelOrderAction, ActorModelOrderState>> {
        await ActorModel(
            initialState: ActorModelOrderState(),
            feature: Feature(
                interactor: ActorModelOrderInteractor(answer: answer, clock: clock, nestedTask: nestedTask)
            )
        )
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeCounterModel(
        clock: EffectClock = EffectClock()
    ) async -> ActorModel<Feature<ActorModelCounterAction, ActorModelCounterState>> {
        await ActorModel(
            initialState: ActorModelCounterState(),
            feature: Feature(interactor: ActorModelCounterInteractor(clock: clock))
        )
    }

    // MARK: Start order

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func effectPreambleRunsBeforeSendReturns() async {
        let answer = Gate()
        let model = await makeOrderModel(answer: answer)

        let (task, state) = await sendThenReadState(.run, on: model)

        // `perform` only enqueues: the effect started after `interact` (and its `defer`) returned,
        // and ran to its first suspension before `send` returned.
        #expect(state.order == ["interact", "interact after perform", "interact defer", "effect preamble"])

        answer.open()
        await task?.value
        #expect(await model.state.order.last == "effect resumed")
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func sendFromAnEffectPreambleIsProcessedDepthFirst() async throws {
        let answer = Gate()
        let nestedTask = LockedNestedTaskBox()
        let model = await makeOrderModel(answer: answer, nestedTask: nestedTask)

        let (task, state) = await sendThenReadState(.outer, on: model)

        #expect(
            state.order == [
                "outer interact",
                "outer effect 1 preamble",
                "inner interact",
                "inner effect preamble",
                "outer effect 1 after send",
                "outer effect 2 preamble",
            ]
        )

        let innerTask = try #require(nestedTask.task)
        answer.open()
        await task?.value
        await innerTask.value
        #expect(await model.state.order.dropFirst(6).sorted() == ["inner effect resumed", "outer effect 1 resumed"])
    }

    /// A task that waited for the inner effect, which sleeps until cancelled, would stall this
    /// test: the time limit reports the stall under the test's name, and the wait is
    /// cancellation-aware so the test then ends instead of hanging the run.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func sendTaskDoesNotCoverTheEffectsOfSendsItsEffectsMake() async throws {
        let clock = EffectClock()
        let nestedTask = LockedNestedTaskBox()
        let model = await makeOrderModel(clock: clock, nestedTask: nestedTask)

        let outerTask = await model.send(.outerSendingLongInner)
        await withTaskCancellationHandler {
            await outerTask?.value
        } onCancel: {
            outerTask?.cancel()
        }

        // The outer effect finished; the inner effect it started through `effects.send` still sleeps.
        #expect(await model.state.order == ["outer effect finished"])
        #expect(clock.sleeperCount == 1)

        let innerTask = try #require(nestedTask.task)
        innerTask.cancel()
        // The send task started immediately, so cancelling it cancelled the effect, whose sleep is
        // gone; checked before the wait, so a cancel that did not arrive fails instead of hanging.
        try #require(clock.sleeperCount == 0)
        await innerTask.value
        #expect(await model.state.order == ["outer effect finished"])  // the inner effect never finished
    }

    // MARK: Cancelled effects

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandledCaseStillDeliversSendsOfEffectsThatIgnoreCancellation() async {
        let model = await makeCounterModel()

        let (tasks, count) = await sendInOneJob(.incrementThenSendDecrement, times: 100, on: model)
        #expect(tasks.count == 100)
        #expect(count == 100)

        for task in tasks { await task.value }
        let state = await model.state
        // Every send but the last cancelled the previous effect while it was suspended at its yield,
        // and every effect still sent its decrement.
        #expect(state.cancelledEffects == 99)
        #expect(state.count == 0)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandledCaseStillCommitsModificationsOfEffectsThatIgnoreCancellation() async {
        let model = await makeCounterModel()

        let (tasks, count) = await sendInOneJob(.incrementThenModifyDecrement, times: 100, on: model)
        #expect(tasks.count == 100)
        #expect(count == 100)

        for task in tasks { await task.value }
        let state = await model.state
        // Every send but the last cancelled the previous effect while it was suspended at its yield,
        // and every effect still committed its decrement.
        #expect(state.cancelledEffects == 99)
        #expect(state.count == 0)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func reHandledCaseLosesTheWorkOfEffectsCancelledAtASleep() async throws {
        let clock = EffectClock()
        let model = await makeCounterModel(clock: clock)

        let (tasks, count) = await sendInOneJob(.incrementThenSleepThenModifyDecrement, times: 100, on: model)
        #expect(tasks.count == 100)
        #expect(count == 100)

        // Each send auto-cancelled the previous effect, whose sleep left the clock inside the send;
        // the last one still sleeps.
        try #require(clock.sleeperCount == 1)
        for task in tasks.dropLast() { await task.value }

        // The cancelled effects threw at their sleep: none of their decrements arrived.
        #expect(await model.state.count == 100)

        let lastTask = try #require(tasks.last)
        lastTask.cancel()
        try #require(clock.sleeperCount == 0)
        await lastTask.value
        #expect(await model.state.count == 100)
    }

    // MARK: Modifications

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func preambleModificationIsVisibleWhenSendReturns() async {
        let model = await makeOrderModel()

        // Read in the job of the send: a preamble that ran as a job of its own would come after it.
        let (_, state) = await sendThenReadState(.modifyInPreamble, on: model)
        #expect(state.count == 11)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func modificationAfterASuspensionIsVisibleOnceTheSendTaskIsDone() async {
        let answer = Gate()
        let model = await makeOrderModel(answer: answer)

        let task = await model.send(.modifyAfterAnswer)
        #expect(await model.state.count == 0)  // the effect waits for the answer

        answer.open()
        await task?.value
        #expect(await model.state.count == 5)
    }

    // MARK: Teardown

    /// The model's `isolated deinit` is a job on the model's executor that runs once the last
    /// reference is gone, after the release returns, so the test waits for the cancellation it
    /// causes. The wait ends when the test is cancelled: a deinit that does not cancel the effect
    /// fails at the time limit instead of hanging the run.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func deinitCancelsASleepingEffectWhoseLaterSendAndModifyThrowWithoutAnIssue() async {
        let log = EffectLog()
        let (cancellations, cancelled) = AsyncStream.makeStream(of: Void.self)

        let issues = await reportedIssueDetails {
            weak var weakModel: ActorModel<Feature<ActorModelTeardownAction, ActorModelTeardownState>>?
            var task: Task<Void, Never>?
            do {
                let model = await ActorModel(
                    initialState: ActorModelTeardownState(),
                    feature: Feature(
                        interactor: ActorModelTeardownInteractor(log: log, clock: EffectClock(), cancelled: cancelled)
                    )
                )
                weakModel = model
                task = await model.send(.sleepThenSendAndModify)
            }
            #expect(weakModel == nil)

            var cancellation = cancellations.makeAsyncIterator()
            guard await cancellation.next() != nil else {
                Issue.record("Releasing the model did not cancel its sleeping effect")
                return
            }
            await task?.value
        }

        #expect(issues == [])
        #expect(log.entries == ["send threw CancellationError", "modify threw CancellationError"])
    }
}
