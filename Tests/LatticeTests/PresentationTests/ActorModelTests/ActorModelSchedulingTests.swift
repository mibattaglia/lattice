import Clocks
import Foundation
import Testing

@testable import Lattice

// Every fixture is declared at file scope, so the interactors and their effect literals are
// nonisolated, as `ActorModel` requires. The tests are nonisolated too and observe effects only
// through `send(…)?.value`, the model's state, gates and logs: an effect may resume on the model's
// executor as soon as a model call returns, so a log is read right after a call only when every
// effect that could still append to it waits at a closed gate or in a sleep that only cancellation
// ends.

// MARK: - Start order and modifications

@FeatureState
struct ActorModelOrderState: Equatable, Sendable {
    var count = 0
}

enum ActorModelOrderAction: Equatable, Sendable {
    case run
    case outer
    case inner
    case outerSendingLongInner
    case longInner
    case modifyInPreamble
    case modifyAfterGate
}

/// The task an effect got back from its own `effects.send`. Locked: the effect sets it on the
/// model's executor, and the test reads it.
final class LockedNestedTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

@Interactor<ActorModelOrderState, ActorModelOrderAction>
struct ActorModelOrderInteractor {
    let log: EffectLog
    let gate: SendableEffectGate
    let clock: TestClock<Duration>
    let nestedTask: LockedNestedTaskBox

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .run:
                log.append("interact")
                defer { log.append("interact defer") }
                effects.perform {
                    log.append("effect preamble")
                    await gate.wait()
                    log.append("effect resumed")
                }
                log.append("interact after perform")

            case .outer:
                log.append("outer interact")
                effects.perform {
                    log.append("outer effect 1 preamble")
                    nestedTask.task = try effects.send(.inner)
                    log.append("outer effect 1 after send")
                    await gate.wait()
                    log.append("outer effect 1 resumed")
                }
                effects.perform {
                    log.append("outer effect 2 preamble")
                }

            case .inner:
                log.append("inner interact")
                effects.perform {
                    log.append("inner effect preamble")
                    await gate.wait()
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

            case .modifyInPreamble:
                state.count += 1
                effects.perform { try effects.modify { $0.count += 10 } }

            case .modifyAfterGate:
                effects.perform {
                    await gate.wait()
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
}

enum ActorModelCounterAction: Equatable, Sendable {
    case incrementThenSendDecrement
    case incrementThenModifyDecrement
    case incrementThenSleepThenModifyDecrement
    case decrement
}

@Interactor<ActorModelCounterState, ActorModelCounterAction>
struct ActorModelCounterInteractor {
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
                    log.append(Task.isCancelled ? "cancelled effect sends" : "effect sends")
                    try effects.send(.decrement)
                }

            case .incrementThenModifyDecrement:
                state.count += 1
                effects.perform {
                    await Task.yield()
                    log.append(Task.isCancelled ? "cancelled effect modifies" : "effect modifies")
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

// MARK: - Teardown

@FeatureState
struct ActorModelTeardownState: Equatable, Sendable {
    var count = 0
}

enum ActorModelTeardownAction: Equatable, Sendable {
    case sleepThenSendAndModify
    case ping
}

@Interactor<ActorModelTeardownState, ActorModelTeardownAction>
struct ActorModelTeardownInteractor {
    let log: EffectLog
    let clock: TestClock<Duration>
    /// Opened by the effect's cancellation handler, for the test to wait on.
    let effectCancelled: SendableEffectGate

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .sleepThenSendAndModify:
                effects.perform {
                    try? await withTaskCancellationHandler {
                        try await clock.sleep(for: .seconds(1_000))
                    } onCancel: { [log, effectCancelled] in
                        log.append("sleep cancelled")
                        effectCancelled.open()
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

/// Sends `action` and reads the count that `send` committed.
@available(iOS 26, macOS 26, watchOS 26, *)
private func sendThenReadCount(
    _ action: ActorModelOrderAction,
    on model: isolated ActorModel<Feature<ActorModelOrderAction, ActorModelOrderState>>
) -> Int {
    model.send(action)
    return model.state.count
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
        log: EffectLog,
        gate: SendableEffectGate = SendableEffectGate(),
        nestedTask: LockedNestedTaskBox = LockedNestedTaskBox()
    ) async -> ActorModel<Feature<ActorModelOrderAction, ActorModelOrderState>> {
        await ActorModel(
            initialState: ActorModelOrderState(),
            feature: Feature(
                interactor: ActorModelOrderInteractor(log: log, gate: gate, clock: TestClock(), nestedTask: nestedTask)
            )
        )
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeCounterModel(
        log: EffectLog = EffectLog()
    ) async -> ActorModel<Feature<ActorModelCounterAction, ActorModelCounterState>> {
        await ActorModel(
            initialState: ActorModelCounterState(),
            feature: Feature(interactor: ActorModelCounterInteractor(log: log, clock: TestClock()))
        )
    }

    // MARK: Start order

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func effectPreambleRunsBeforeSendReturns() async {
        let log = EffectLog()
        let gate = SendableEffectGate()
        let model = await makeOrderModel(log: log, gate: gate)

        let task = await model.send(.run)

        // `perform` only enqueues: the effect started after `interact` (and its `defer`) returned,
        // and ran to its first suspension before `send` returned.
        #expect(log.entries == ["interact", "interact after perform", "interact defer", "effect preamble"])

        gate.open()
        await task?.value
        #expect(log.entries.last == "effect resumed")
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func sendFromAnEffectPreambleIsProcessedDepthFirst() async throws {
        let log = EffectLog()
        let gate = SendableEffectGate()
        let nestedTask = LockedNestedTaskBox()
        let model = await makeOrderModel(log: log, gate: gate, nestedTask: nestedTask)

        let task = await model.send(.outer)

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

        let innerTask = try #require(nestedTask.task)
        gate.open()
        await task?.value
        await innerTask.value
        #expect(log.entries.dropFirst(6).sorted() == ["inner effect resumed", "outer effect 1 resumed"])
    }

    /// A task that waited for the inner effect, which sleeps until cancelled, would stall this
    /// test: the time limit reports the stall under the test's name, and the wait is
    /// cancellation-aware so the test then ends instead of hanging the run.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func sendTaskDoesNotCoverTheEffectsOfSendsItsEffectsMake() async throws {
        let log = EffectLog()
        let nestedTask = LockedNestedTaskBox()
        let model = await makeOrderModel(log: log, nestedTask: nestedTask)

        let outerTask = await model.send(.outerSendingLongInner)
        await withTaskCancellationHandler {
            await outerTask?.value
        } onCancel: {
            outerTask?.cancel()
        }

        // The outer effect finished; the inner effect it started through `effects.send` still sleeps.
        #expect(log.entries == ["outer effect finished"])

        let innerTask = try #require(nestedTask.task)
        innerTask.cancel()
        // The send task started immediately, so cancelling it cancelled the effect; checked before
        // the wait, so a cancel that did not arrive fails instead of hanging.
        try #require(log.entries == ["outer effect finished", "inner effect cancelled"])
        await innerTask.value
        #expect(log.entries == ["outer effect finished", "inner effect cancelled"])
    }

    // MARK: Cancelled effects

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func reHandledCaseStillDeliversSendsOfEffectsThatIgnoreCancellation() async {
        let log = EffectLog()
        let model = await makeCounterModel(log: log)

        let (tasks, count) = await sendInOneJob(.incrementThenSendDecrement, times: 100, on: model)
        #expect(tasks.count == 100)
        #expect(count == 100)

        for task in tasks { await task.value }
        // Every send but the last cancelled the previous effect while it was suspended at its yield.
        #expect(log.entries.sorted() == Array(repeating: "cancelled effect sends", count: 99) + ["effect sends"])
        #expect(await model.state.count == 0)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func reHandledCaseStillCommitsModificationsOfEffectsThatIgnoreCancellation() async {
        let log = EffectLog()
        let model = await makeCounterModel(log: log)

        let (tasks, count) = await sendInOneJob(.incrementThenModifyDecrement, times: 100, on: model)
        #expect(tasks.count == 100)
        #expect(count == 100)

        for task in tasks { await task.value }
        // Every send but the last cancelled the previous effect while it was suspended at its yield.
        #expect(
            log.entries.sorted() == Array(repeating: "cancelled effect modifies", count: 99) + ["effect modifies"]
        )
        #expect(await model.state.count == 0)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func reHandledCaseLosesTheWorkOfEffectsCancelledAtASleep() async throws {
        let log = EffectLog()
        let model = await makeCounterModel(log: log)

        let (tasks, count) = await sendInOneJob(.incrementThenSleepThenModifyDecrement, times: 100, on: model)
        #expect(tasks.count == 100)
        #expect(count == 100)

        // Each send auto-cancelled the previous effect; the last one still sleeps.
        try #require(log.entries == Array(repeating: "sleep cancelled", count: 99))
        for task in tasks.dropLast() { await task.value }

        // The cancelled effects threw at their sleep: none of their decrements arrived.
        #expect(await model.state.count == 100)

        let lastTask = try #require(tasks.last)
        lastTask.cancel()
        try #require(log.entries.count == 100)
        await lastTask.value
        #expect(await model.state.count == 100)
    }

    // MARK: Modifications

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func preambleModificationIsVisibleWhenSendReturns() async {
        let model = await makeOrderModel(log: EffectLog())

        // Read in the job of the send: a preamble that ran as a job of its own would come after it.
        let count = await sendThenReadCount(.modifyInPreamble, on: model)
        #expect(count == 11)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func modificationAfterASuspensionIsVisibleOnceTheSendTaskIsDone() async {
        let gate = SendableEffectGate()
        let model = await makeOrderModel(log: EffectLog(), gate: gate)

        let task = await model.send(.modifyAfterGate)
        #expect(await model.state.count == 0)  // the effect waits at the gate

        gate.open()
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
        let effectCancelled = SendableEffectGate()

        let issues = await reportedIssueDetails {
            weak var weakModel: ActorModel<Feature<ActorModelTeardownAction, ActorModelTeardownState>>?
            var task: Task<Void, Never>?
            do {
                let model = await ActorModel(
                    initialState: ActorModelTeardownState(),
                    feature: Feature(
                        interactor: ActorModelTeardownInteractor(
                            log: log,
                            clock: TestClock(),
                            effectCancelled: effectCancelled
                        )
                    )
                )
                weakModel = model
                task = await model.send(.sleepThenSendAndModify)
            }
            #expect(weakModel == nil)

            do {
                try await effectCancelled.pass()
            } catch {
                Issue.record("Releasing the model did not cancel its sleeping effect: \(log.entries)")
                return
            }
            await task?.value
        }

        #expect(issues == [])
        #expect(log.entries == ["sleep cancelled", "send threw CancellationError", "modify threw CancellationError"])
    }
}
