import Foundation
import Testing

@testable import Lattice

/// `skipInFlightEffects` cancels what is in flight and waits for it to unwind; what the cancelled
/// effects commit while unwinding stays pending.
@Suite
struct TestModelCancellationTests {
    /// Port of the old `skipInFlightEffectsCancelsRunningEffectWork`: the gated effect never gets
    /// past its gate, and its `defer` modification is pending for `expect`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func skipInFlightEffectsCancelsAWaitingEffectWhoseDeferModificationStaysPending() async {
        let gate = Gate()
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel(LoadInteractor(gate: gate))
            let task = await model.send(.gated) { $0.isLoading = true }
            await model.skipInFlightEffects()
            await task?.value
            await model.expect { $0.isLoading = false }
            #expect(await model.state.count == 0)
            await model.finish()
        }

        #expect(issues == [])
    }

    /// A cancelled effect can still send an action that starts another effect:
    /// `skipInFlightEffects` cancels again on every signal until nothing is left in flight. Both
    /// hangs end only when cancelled, so a wait that missed one would report a timeout.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func skipInFlightEffectsAlsoCancelsTheEffectsACancelledEffectStarts() async {
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.hangThenHangAgainWhenCancelled)
            await model.skipInFlightEffects()
            await model.receive(.hang)  // sent by the first hang once it was cancelled
            await model.finish()
        }

        #expect(issues == [])
    }

    /// Port of the old `skipInFlightEffectsReportsMissingWorkAtCaller`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func skipInFlightEffectsWithNoEffectInFlightReportsItWhenStrict() async {
        var skipLine = 0
        let issues = await reportedIssueDetails {
            let model = await makeLoadModel()
            await model.send(.increment) { $0.count = 1 }
            skipLine = #line + 1
            await model.skipInFlightEffects()
            await model.skipInFlightEffects(strict: false)
            await model.finish()
        }

        #expect(issues.map(\.line) == [skipLine])
        #expect(issues.map(\.message) == ["There were no in-flight effects to skip."])
    }
}
