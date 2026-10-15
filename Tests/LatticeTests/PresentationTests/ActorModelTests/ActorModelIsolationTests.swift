import Clocks
import Foundation
import Testing

@testable import Lattice

@FeatureState
struct ActorModelIsolationProbeState: Equatable, Sendable {
    var isFinished = false
}

enum ActorModelIsolationProbeAction: Equatable, Sendable {
    case start
    case stop
}

// Declared at file scope, so the interactor and the effect literal in its `body` are nonisolated:
// the effect gets the model's executor only from the start phase of the runtime. A literal written
// in a context isolated to the model would hide a start phase that lost the isolation (an effect
// task created in a closure nested inside `assumeIsolated` starts synchronously but resumes on the
// global executor).
@Interactor<ActorModelIsolationProbeState, ActorModelIsolationProbeAction>
struct ActorModelIsolationProbeInteractor {
    @EffectID var probe
    let clock: TestClock<Duration>
    let log: EffectLog
    let modelReference: ActorShellReference

    /// Traps unless the effect runs on the actor model's executor; logs `point` when it checked.
    private func checkIsolation(_ point: String) {
        guard let model = modelReference.shell else {
            log.append("no model to check \(point)")
            return
        }
        model.preconditionIsolated("The effect ran off the actor model's executor \(point)")
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

/// The `ActorModel` part of the isolation regression (with `TestModelIsolationTests` and
/// `ViewModelIsolationTests`). With the forbidden `map` in `Core.startQueued`, the effect task has no
/// isolation and `preconditionIsolated` traps.
@Suite
struct ActorModelIsolationTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func effectFormedInANonisolatedContextResumesOnTheActorModelsExecutor() async {
        let log = EffectLog()
        let modelReference = ActorShellReference()
        let model = await ActorModel(
            initialState: ActorModelIsolationProbeState(),
            feature: Feature(
                interactor: ActorModelIsolationProbeInteractor(
                    clock: TestClock(),
                    log: log,
                    modelReference: modelReference
                )
            )
        )
        modelReference.shell = model

        let task = await model.send(.start)
        #expect(log.entries == ["on the model's executor in the preamble"])

        // `.stop` cancels the sleeping effect, which carries on after its sleep. Checked before the
        // wait, so a cancel that did not arrive fails the test instead of hanging it. Only the first
        // two entries: the cancelled effect may already have resumed and logged more.
        await model.send(.stop)
        guard log.entries.prefix(2) == ["on the model's executor in the preamble", "sleep cancelled"] else {
            Issue.record("The sleeping effect was not cancelled: \(log.entries)")
            return
        }
        await task?.value

        #expect(await model.state.isFinished)
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
