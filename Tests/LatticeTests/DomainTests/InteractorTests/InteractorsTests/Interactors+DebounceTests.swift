import Foundation
import Testing

@testable import Lattice

// The `Interactors.Debounce` semantics of the plan's §4.2, one test per guarantee. Time is a
// `GateClock`: a test waits until the sleeps it means to end have registered, then moves the clock
// forward, so no assertion depends on when an effect hops off the model's executor to sleep.

// MARK: - Fixtures

@FeatureState
struct DebounceState: Equatable, Sendable {
    var triggerCount = 0
    /// How many delayed `.trigger` effects ran, and the trigger count the last one carried.
    var triggerRuns = 0
    var triggerResult = 0
    var otherCount = 0
    var otherRuns = 0
    var saved: [Int] = []
}

enum DebounceAction: Equatable, Sendable {
    case trigger
    case other
    case save(Int)
}

/// The child the tests debounce. `.trigger` and `.other` each perform an anonymous effect that
/// records its run in state; `.save` performs an effect identified by `save`.
@Interactor<DebounceState, DebounceAction>
struct DebounceChildInteractor {
    @EffectID var save

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .trigger:
                state.triggerCount += 1
                let trigger = state.triggerCount
                effects.perform {
                    try effects.modify {
                        $0.triggerRuns += 1
                        $0.triggerResult = trigger
                    }
                }
            case .other:
                state.otherCount += 1
                effects.perform { try effects.modify { $0.otherRuns += 1 } }
            case .save(let value):
                effects.perform(id: save) { try effects.modify { $0.saved.append(value) } }
            }
        }
    }
}

/// Builds its `Debounce` inside `body`, so every action is handled by a new `Debounce` and a new
/// child, as in the README's examples.
@Interactor<DebounceState, DebounceAction>
struct DebounceInBodyInteractor {
    let clock: GateClock

    var body: some InteractorOf<Self> {
        Interactors.Debounce(for: .milliseconds(300), clock: clock) {
            DebounceChildInteractor()
        }
    }
}

/// A test model over `interactor`, forwarding the caller's location. The timeout is generous: the
/// cancelled effects unwind through the cooperative pool, which other suites keep busy.
@available(iOS 26, macOS 26, watchOS 26, *)
private func makeDebounceModel(
    _ interactor: sending some Interactor<DebounceState, DebounceAction>,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> TestModel<Feature<DebounceAction, DebounceState>> {
    await TestModel(
        initialState: DebounceState(),
        feature: Feature(interactor: interactor),
        timeout: .seconds(10),
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

// MARK: - Tests

@Suite
struct DebounceInteractorTests {
    /// Mutations are not debounced: each send's change is committed and asserted at once, while
    /// the effects it started wait out the quiet period.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func stateChangesImmediatelyOnEachAction() async {
        let clock = GateClock()
        let issues = await reportedIssueDetails {
            let model = await makeDebounceModel(
                Interactors.Debounce(for: .milliseconds(300), clock: clock) { DebounceChildInteractor() }
            )
            await model.send(.trigger) { $0.triggerCount = 1 }
            await model.send(.other) { $0.otherCount = 1 }
            await model.send(.trigger) { $0.triggerCount = 2 }

            // The `.other` effect and the second `.trigger` effect sleep; no effect has run, so the
            // live state is the asserted one.
            await clock.waitForSleepers(2)
            #expect(clock.pendingSleeps == [.milliseconds(300), .milliseconds(300)])
            await model.expect { _ in }
            await model.skipInFlightEffects()
            await model.finish()
        }

        #expect(issues == [])
    }

    /// A child that performs no effect has nothing to delay: every action passes straight through
    /// and its send starts no task.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func childWithoutEffectsPassesThrough() async {
        let clock = GateClock()
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: CounterState(count: 0),
                feature: Feature(
                    interactor: Interactors.Debounce(for: .milliseconds(300), clock: clock) { CounterInteractor() }
                )
            )
            let tasks = [
                await model.send(.increment) { $0.count = 1 },
                await model.send(.decrement) { $0.count = 0 },
                await model.send(.increment) { $0.count = 1 },
            ]
            #expect(tasks.allSatisfy { $0 == nil })
            #expect(clock.pendingSleeps == [])
            await model.finish()
        }

        #expect(issues == [])
    }

    /// Each repeat of `.trigger` starts one delayed effect, and the next repeat cancels it inside
    /// its send. The test waits for each sleep to register before the next send, so the clock's log
    /// is exact: no clock time passes between the sends.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func rapidRepeatsStartOneDelayedEffectEachAndCancelThePreviousOne() async {
        let log = EffectLog()
        let clock = GateClock(log: log)
        let issues = await reportedIssueDetails {
            let model = await makeDebounceModel(
                Interactors.Debounce(for: .milliseconds(300), clock: clock) { DebounceChildInteractor() }
            )
            await model.send(.trigger) { $0.triggerCount = 1 }
            await clock.waitForSleepers(1)
            await model.send(.trigger) { $0.triggerCount = 2 }
            // The second send cancelled the first sleep before it returned; the second sleep can
            // only register after that.
            #expect(log.entries.prefix(2) == ["sleep 1 for 0.3 seconds", "sleep 1 cancelled"])

            await clock.waitForSleepers(1)
            await model.send(.trigger) { $0.triggerCount = 3 }
            #expect(
                log.entries.prefix(4) == [
                    "sleep 1 for 0.3 seconds",
                    "sleep 1 cancelled",
                    "sleep 2 for 0.3 seconds",
                    "sleep 2 cancelled",
                ]
            )

            await clock.waitForSleepers(1)
            await model.skipInFlightEffects()
            await model.finish()
        }

        #expect(issues == [])
        #expect(
            log.entries == [
                "sleep 1 for 0.3 seconds",
                "sleep 1 cancelled",
                "sleep 2 for 0.3 seconds",
                "sleep 2 cancelled",
                "sleep 3 for 0.3 seconds",
                "sleep 3 cancelled",
            ]
        )
    }

    /// Back-to-back repeats coalesce to the last one: it is the only effect left sleeping, it does
    /// not run before the quiet period has passed, and then it commits its modification.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func lastEffectRunsAfterTheQuietPeriodAndCommitsItsModification() async {
        let clock = GateClock()
        let issues = await reportedIssueDetails {
            let model = await makeDebounceModel(
                Interactors.Debounce(for: .milliseconds(300), clock: clock) { DebounceChildInteractor() }
            )
            await model.send(.trigger) { $0.triggerCount = 1 }
            await model.send(.trigger) { $0.triggerCount = 2 }
            let task = await model.send(.trigger) { $0.triggerCount = 3 }

            // The first two effects were cancelled, registered or not; only the third sleeps.
            await clock.waitForSleepers(1)
            #expect(clock.pendingSleeps == [.milliseconds(300)])

            clock.moveForward(by: .milliseconds(299))
            #expect(clock.pendingSleeps == [.milliseconds(1)])
            await model.expect { _ in }  // still inside the quiet period: no effect has run

            clock.moveForward(by: .milliseconds(1))
            await task?.value
            await model.expect {
                $0.triggerRuns = 1
                $0.triggerResult = 3
            }
            await model.finish()
        }

        #expect(issues == [])
    }

    /// Auto-cancel is per action case: `.other` leaves the sleeping `.trigger` effect alone, and a
    /// repeated `.trigger` cancels only the `.trigger` effect.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func differentActionCasesDoNotCancelEachOthersDelayedEffects() async {
        let log = EffectLog()
        let clock = GateClock(log: log)
        let issues = await reportedIssueDetails {
            let model = await makeDebounceModel(
                Interactors.Debounce(for: .milliseconds(300), clock: clock) { DebounceChildInteractor() }
            )
            await model.send(.trigger) { $0.triggerCount = 1 }
            await clock.waitForSleepers(1)
            let otherTask = await model.send(.other) { $0.otherCount = 1 }
            #expect(!log.entries.contains("sleep 1 cancelled"))  // a cancel would have run inside the send

            await clock.waitForSleepers(2)
            let triggerTask = await model.send(.trigger) { $0.triggerCount = 2 }
            #expect(
                log.entries.prefix(3) == [
                    "sleep 1 for 0.3 seconds",
                    "sleep 2 for 0.3 seconds",
                    "sleep 1 cancelled",
                ]
            )

            await clock.waitForSleepers(2)
            clock.moveForward(by: .milliseconds(300))
            await otherTask?.value
            await triggerTask?.value
            await model.expect {
                $0.otherRuns = 1
                $0.triggerRuns = 1
                $0.triggerResult = 2
            }
            await model.finish()
        }

        #expect(issues == [])
        #expect(
            log.entries == [
                "sleep 1 for 0.3 seconds",
                "sleep 2 for 0.3 seconds",
                "sleep 1 cancelled",
                "sleep 3 for 0.3 seconds",
                "sleep 2 woke",
                "sleep 3 woke",
            ]
        )
    }

    /// `Debounce` wraps every effect the child enqueues, identified ones included: a `perform(id:)`
    /// effect waits out the quiet period too, and the next one of its key replaces it while it
    /// sleeps.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func identifiedEffectsAreDelayedToo() async {
        let log = EffectLog()
        let clock = GateClock(log: log)
        let issues = await reportedIssueDetails {
            let model = await makeDebounceModel(
                Interactors.Debounce(for: .milliseconds(300), clock: clock) { DebounceChildInteractor() }
            )
            await model.send(.save(1))
            await clock.waitForSleepers(1)
            #expect(log.entries == ["sleep 1 for 0.3 seconds"])
            await model.expect { _ in }  // the identified effect is sleeping, not saving

            let task = await model.send(.save(2))  // replaces the sleeping effect of the same key
            #expect(log.entries.prefix(2) == ["sleep 1 for 0.3 seconds", "sleep 1 cancelled"])

            await clock.waitForSleepers(1)
            clock.moveForward(by: .milliseconds(300))
            await task?.value
            await model.expect { $0.saved = [2] }
            await model.finish()
        }

        #expect(issues == [])
        #expect(
            log.entries == [
                "sleep 1 for 0.3 seconds",
                "sleep 1 cancelled",
                "sleep 2 for 0.3 seconds",
                "sleep 2 woke",
            ]
        )
    }

    /// A `Debounce` built inside `body` is a new value on every action, and still coalesces: it
    /// holds no per-instance token, and auto-cancel keys the delayed effects by action case. (The
    /// former `Interactors.Debounce` minted a token per instance, so in this position it never
    /// debounced.)
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func debounceBuiltInsideBodyStillCoalesces() async {
        let log = EffectLog()
        let clock = GateClock(log: log)
        let issues = await reportedIssueDetails {
            let model = await makeDebounceModel(DebounceInBodyInteractor(clock: clock))
            await model.send(.trigger) { $0.triggerCount = 1 }
            await clock.waitForSleepers(1)
            await model.send(.trigger) { $0.triggerCount = 2 }
            #expect(log.entries.prefix(2) == ["sleep 1 for 0.3 seconds", "sleep 1 cancelled"])

            await clock.waitForSleepers(1)
            let task = await model.send(.trigger) { $0.triggerCount = 3 }
            #expect(
                log.entries.prefix(4) == [
                    "sleep 1 for 0.3 seconds",
                    "sleep 1 cancelled",
                    "sleep 2 for 0.3 seconds",
                    "sleep 2 cancelled",
                ]
            )

            await clock.waitForSleepers(1)
            clock.moveForward(by: .milliseconds(300))
            await task?.value
            await model.expect {
                $0.triggerRuns = 1
                $0.triggerResult = 3
            }
            await model.finish()
        }

        #expect(issues == [])
        #expect(
            log.entries == [
                "sleep 1 for 0.3 seconds",
                "sleep 1 cancelled",
                "sleep 2 for 0.3 seconds",
                "sleep 2 cancelled",
                "sleep 3 for 0.3 seconds",
                "sleep 3 woke",
            ]
        )
    }

    /// The `ContinuousClock` convenience initializer: one real 20 ms quiet period. Nothing waits
    /// with a deadline; the time limit only turns a hang into a failure.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func continuousClockConvenienceInitDelaysTheEffect() async {
        let issues = await reportedIssueDetails {
            let model = await makeDebounceModel(
                Interactors.Debounce(for: .milliseconds(20)) { DebounceChildInteractor() }
            )
            let start = ContinuousClock.now
            await model.send(.trigger) { $0.triggerCount = 1 }?.value
            #expect(ContinuousClock.now - start >= .milliseconds(20))
            await model.expect {
                $0.triggerRuns = 1
                $0.triggerResult = 1
            }
            await model.finish()
        }

        #expect(issues == [])
    }

    /// The main-actor shell runs the same debounce: the delayed effect resumes on the main actor.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func testViewModelDebouncesTheSameWay() async {
        let clock = GateClock()
        let issues = await reportedIssueDetails {
            let debounced = Interactors.Debounce(for: .milliseconds(300), clock: clock) { DebounceChildInteractor() }
            let model = TestViewModel(
                initialState: DebounceState(),
                feature: Feature(interactor: debounced),
                timeout: .seconds(10)
            )
            model.send(.trigger) { $0.triggerCount = 1 }
            model.send(.trigger) { $0.triggerCount = 2 }
            let task = model.send(.trigger) { $0.triggerCount = 3 }
            await clock.waitForSleepers(1)
            clock.moveForward(by: .milliseconds(300))
            await task?.value
            model.expect {
                $0.triggerRuns = 1
                $0.triggerResult = 3
            }
            await model.finish()
        }

        #expect(issues == [])
    }
}
