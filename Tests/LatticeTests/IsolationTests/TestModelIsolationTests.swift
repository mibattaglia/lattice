import Clocks
import Foundation
import Testing

@testable import Lattice

@FeatureState
struct TestModelIsolationProbeState: Equatable, Sendable {
    var isFinished = false
}

enum TestModelIsolationProbeAction: Equatable, Sendable {
    case start
    case stop
}

/// The test model under test, for its effect to check that it runs on the model's executor. The
/// model's `host` and `core` are private, so the check goes through the model actor, which shares
/// the core's executor. Weak, so the interactor does not keep its model alive, and locked: the test
/// sets it, the effect reads it on the model's executor.
final class TestModelReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storage: (any Actor)?

    var model: (any Actor)? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

// Declared at file scope, so the interactor and the effect literal in its `body` are nonisolated:
// the effect gets the model's executor only from the start phase of the runtime. A literal written
// in a context isolated to the model would hide a start phase that lost the isolation (an effect
// task created in a closure nested inside `assumeIsolated` starts synchronously but resumes on the
// global executor).
@Interactor<TestModelIsolationProbeState, TestModelIsolationProbeAction>
struct TestModelIsolationProbeInteractor {
    @EffectID var probe
    let clock: TestClock<Duration>
    let log: EffectLog
    let modelReference: TestModelReference

    /// Traps unless the effect runs on the test model's executor; logs `point` when it checked.
    private func checkIsolation(_ point: String) {
        guard let model = modelReference.model else {
            log.append("no model to check \(point)")
            return
        }
        model.preconditionIsolated("The effect ran off the test model's executor \(point)")
        log.append("on the model's executor \(point)")
    }

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .start:
                effects.perform(id: probe) {
                    checkIsolation("in the preamble")
                    // `TestClock.sleep` is `@concurrent`: the effect hops to the global executor and
                    // must come back. `.stop` ends the sleep by cancelling the effect, because an
                    // `advance` right after the send races the sleeper's registration there.
                    do {
                        try await withTaskCancellationHandler {
                            try await clock.sleep(for: .seconds(1))
                        } onCancel: { [log] in
                            log.append("sleep cancelled")  // synchronously, inside the cancelling send
                        }
                        log.append("TestClock.sleep returned")
                    } catch {
                        checkIsolation("after TestClock.sleep")
                    }
                    await Task.yield()
                    checkIsolation("after Task.yield")
                    try effects.modify { $0.isFinished = true }
                }

            case .stop:
                effects.cancel(probe)
            }
        }
    }
}

/// The `TestModel` half of the isolation regression (the `ViewModel` half is
/// `ViewModelIsolationTests`). It is the shape that detects the effect start losing the model's
/// isolation: with the forbidden `map` in `Core.startQueued`, `preconditionIsolated` traps.
@Suite
struct TestModelIsolationTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func effectFormedInANonisolatedContextResumesOnTheTestModelsExecutor() async throws {
        let log = EffectLog()
        let modelReference = TestModelReference()
        let issues = await reportedIssueDetails {
            let model = await TestModel(
                initialState: TestModelIsolationProbeState(),
                feature: Feature(
                    interactor: TestModelIsolationProbeInteractor(
                        clock: TestClock(),
                        log: log,
                        modelReference: modelReference
                    )
                )
            )
            modelReference.model = model

            let task = await model.send(.start)
            #expect(log.entries == ["on the model's executor in the preamble"])

            // `.stop` cancels the sleeping effect, which carries on after its sleep. Checked before
            // the wait, so a cancel that did not arrive fails the test instead of hanging it. Only the
            // first two entries: the cancelled effect may already have resumed and logged more.
            await model.send(.stop)
            guard log.entries.prefix(2) == ["on the model's executor in the preamble", "sleep cancelled"] else {
                Issue.record("The sleeping effect was not cancelled: \(log.entries)")
                return
            }
            await task?.value

            await model.expect { $0.isFinished = true }
            await model.finish()
        }

        #expect(issues == [])
        #expect(
            log.entries == [
                "on the model's executor in the preamble",
                "sleep cancelled",
                "on the model's executor after TestClock.sleep",
                "on the model's executor after Task.yield",
            ]
        )
    }
}
