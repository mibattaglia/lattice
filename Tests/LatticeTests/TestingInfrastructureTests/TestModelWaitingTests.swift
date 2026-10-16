import Foundation
import Testing

@testable import Lattice

/// How `receive`, `finish` and `skipInFlightEffects` wait: on the model's signal, until what they
/// wait for holds, nothing is left in flight, or the timeout passes; one wait at a time.
@Suite
struct TestModelWaitingTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func sendThatStartsNoEffectReturnsNil() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            let task = await model.send(.increment) { $0.count = 1 }
            #expect(task == nil)
            await model.finish()
        }

        #expect(issues == [])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func receiveWaitsForAnActionSentAfterASuspension() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.loadAfterYield)
            await model.receive(.loaded(41)) { $0.count = 41 }

            let sleeping = await model.send(.loadAfterSleep(.milliseconds(50)))
            await model.receive(.loaded(41), timeout: .seconds(5)) { $0.count = 82 }
            await sleeping?.value
            await model.finish()
        }

        #expect(issues == [])
    }

    /// The `receive`'s own timeout ends the wait (the model's default here is 10 seconds), and the
    /// report says effects are still in flight.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func receiveTimesOutWhileAnEffectIsInFlight() async {
        var receiveLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel(timeout: .seconds(10))
            await model.send(.hang)
            let start = ContinuousClock.now
            receiveLine = #line + 1
            await model.receive(.loaded(41), timeout: .milliseconds(50))
            let elapsed = ContinuousClock.now - start
            #expect(elapsed >= .milliseconds(50))
            #expect(elapsed < .seconds(5))
            await model.skipInFlightEffects()
            await model.finish()
        }

        #expect(issues.map(\.line) == [receiveLine])
        #expect(
            issues.map(\.heading) == ["Expected to receive the following action, but didn't after 0.05 seconds:"]
        )
        #expect(issues.first?.message.contains("LoadAction.loaded(41)") == true)
        #expect(issues.first?.message.contains("There are effects in flight.") == true)
    }

    /// With no effect in flight, nothing can send the action: `receive` fails right away, without
    /// waiting for its timeout.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func receiveFailsAtOnceWhenNoEffectIsInFlight() async {
        var receiveLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.increment) { $0.count = 1 }
            let start = ContinuousClock.now
            receiveLine = #line + 1
            await model.receive(.loaded(1), timeout: .seconds(10))
            #expect(ContinuousClock.now - start < .seconds(5))
            await model.finish()
        }

        #expect(issues.map(\.line) == [receiveLine])
        #expect(issues.map(\.heading) == ["Expected to receive the following action, but didn't:"])
        #expect(
            issues.first?.message.contains("There are no in-flight effects that could send this action.") == true
        )
    }

    /// Exhaustive: `receive` waits past a different action for the one it expects, reports the
    /// other one and folds it into its assertion.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func receiveWaitsPastANonMatchingActionAndReportsItWhenExhaustive() async {
        var receiveLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.startSequence)
            receiveLine = #line + 1
            await model.receive(.step(2)) { $0.values = [1, 2] }
            await model.finish()
        }

        #expect(issues.map(\.line) == [receiveLine])
        #expect(issues.map(\.heading) == ["Received unexpected action before this one:"])
        #expect(issues.first?.message.contains("step(1)") == true)
    }

    /// Effects start effects: each `.chain` sends the next after a yield. `finish` re-reads what is
    /// in flight on every signal until all of them are done, then skips what they committed.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func finishWaitsForEffectsThatEffectsStart() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel(exhaustivity: .off(showSkippedAssertions: false))
            await model.send(.chain(5))
            await model.finish()
            #expect(await model.state.chained == [5, 4, 3, 2, 1, 0])
        }

        #expect(issues == [])
    }

    /// Port of the old `finishReportsTimeoutWhileEmissionRemainsInFlight`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func finishTimesOutWhileAnEffectStaysInFlight() async {
        var finishLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel(timeout: .seconds(10))
            await model.send(.hang)
            let start = ContinuousClock.now
            finishLine = #line + 1
            await model.finish(timeout: .milliseconds(20))
            #expect(ContinuousClock.now - start >= .milliseconds(20))
            await model.skipInFlightEffects()
            await model.finish()
        }

        #expect(issues.map(\.line) == [finishLine])
        #expect(
            issues.map(\.message) == ["Expected effects to finish, but 1 effect remained in flight after 0.02 seconds."]
        )
    }

    /// Port of the old `finishReportsBufferedReceivesProducedWhileWaiting`: what effects sent while
    /// `finish` waited is reported and consumed.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func finishReportsTheActionsEffectsSentWhileItWaited() async {
        var finishLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.loadAfterSleep(.milliseconds(50)))
            finishLine = #line + 1
            await model.finish(timeout: .seconds(5))
            #expect(await model.state.count == 41)
            await model.finish()
        }

        #expect(issues.map(\.line) == [finishLine])
        #expect(issues.map(\.isWarning) == [false])
        #expect(
            issues.map(\.message) == [
                """
                Received 1 unexpected action left unhandled.

                Unhandled actions: [
                  [0]: .loaded(41)
                ]
                """
            ]
        )
    }

    /// While one `receive` waits, a second `receive`, a `finish` and a `skipInFlightEffects` each
    /// report the overlap and do nothing else: nothing is consumed, settled or cancelled, so the
    /// first `receive` still gets its action.
    ///
    /// The first `receive` runs in an immediate task, which enqueues it on the model's executor
    /// before the test's next call: it is waiting by the time those calls run.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func overlappingWaitsReportTheOverlapAndDoNothingElse() async {
        let gate = Gate()
        var lines: [Int] = []
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel(LoadInteractor(gate: gate), timeout: .seconds(10))
            await model.send(.gatedLoad)
            let firstReceive = Task.immediate {
                await model.receive(.loaded(41)) { $0.count = 41 }
            }
            lines.append(#line + 1)
            await model.receive(.loaded(41))
            lines.append(#line + 1)
            await model.finish()
            lines.append(#line + 1)
            await model.skipInFlightEffects()
            gate.open()
            await firstReceive.value
            #expect(await model.state.count == 41)
            await model.finish()
        }

        #expect(issues.map(\.message) == Array(repeating: overlappingWaitMessage, count: 3))
        #expect(issues.map(\.line) == lines)
    }

    /// Cancelling a task that waits in `receive` ends the signal stream it waits on: when the task
    /// is cancelled while it waits, and when the cancel lands with the commit it waits for (the wait
    /// then ends with what it waited for). The model renews the stream, so a later wait still waits
    /// for its whole timeout instead of ending at once.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func aCancelledWaitDoesNotBreakLaterWaits() async {
        var lines: [Int] = []
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.hang)
            lines.append(#line + 2)
            let waiting = Task.immediate {
                await model.receive(.loaded(41), timeout: .seconds(10))
            }
            _ = await model.state  // after the waiting task's job on the model's executor
            waiting.cancel()
            await waiting.value

            let start = ContinuousClock.now
            lines.append(#line + 1)
            await model.receive(.loaded(41), timeout: .milliseconds(100))
            #expect(ContinuousClock.now - start >= .milliseconds(100))
            await model.skipInFlightEffects()
            await model.finish()
        }

        #expect(
            issues.map(\.heading) == [
                "Expected to receive the following action, but didn't before the wait was cancelled:",
                "Expected to receive the following action, but didn't after 0.1 seconds:",
            ]
        )
        #expect(issues.map(\.line) == lines)

        let gate = Gate()
        let waiter = LockedTaskBox()
        let coinciding = await reportedIssueDetails {
            let model = await makeLoadModel(LoadInteractor(gate: gate, waiter: waiter))
            await model.send(.gatedLoadCancellingWaiter)
            let waiting = Task.immediate {
                await model.receive(.loaded(41)) { $0.count = 41 }
            }
            waiter.set(waiting)
            _ = await model.state  // after the waiting task's job on the model's executor
            gate.open()  // one job: commit `.loaded(41)`, then cancel `waiting`
            await waiting.value  // it still received `.loaded(41)`

            await model.send(.hang)
            let start = ContinuousClock.now
            await model.receive(.loaded(41), timeout: .milliseconds(100))
            #expect(ContinuousClock.now - start >= .milliseconds(100))
            await model.skipInFlightEffects()
            await model.finish()
        }

        #expect(
            coinciding.map(\.heading) == ["Expected to receive the following action, but didn't after 0.1 seconds:"]
        )
    }

    /// A wait cut short by cancelling the task that waits is reported as cancelled, not as timed
    /// out, by `receive`, `finish` and `skipInFlightEffects` alike. The effect ignores
    /// cancellation, so it stays in flight through all three waits.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func waitsCutShortByCancellationAreReportedAsCancelled() async {
        let gate = Gate()
        var lines: [Int] = []
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel(LoadInteractor(gate: gate), timeout: .seconds(10))
            await model.send(.gatedIgnoringCancellation)

            lines.append(#line + 1)
            let receiving = Task.immediate { await model.receive(.loaded(41)) }
            _ = await model.state  // after the waiting task's job on the model's executor: it waits
            receiving.cancel()
            await receiving.value

            lines.append(#line + 1)
            let finishing = Task.immediate { await model.finish() }
            _ = await model.state
            finishing.cancel()
            await finishing.value

            lines.append(#line + 1)
            let skipping = Task.immediate { await model.skipInFlightEffects() }
            _ = await model.state
            skipping.cancel()
            await skipping.value

            gate.open()
            await model.finish()
        }

        #expect(issues.map(\.line) == lines)
        #expect(
            issues.map(\.heading) == [
                "Expected to receive the following action, but didn't before the wait was cancelled:",
                "Expected effects to finish, but 1 effect remained in flight when the wait was cancelled.",
                "Expected effects to finish, but 1 effect remained in flight when the wait was cancelled.",
            ]
        )
    }
}

private let overlappingWaitMessage = """
    The test model is already waiting for its effects, so this call did nothing: 'receive', \
    'finish' and 'skipInFlightEffects' each wait; await one before starting another.
    """
