import Clocks
import Foundation
import Testing

@testable import Lattice

@FeatureState
struct IsolationProbeState: Equatable {
    var isFinished = false
}

enum IsolationProbeAction {
    case start
}

/// Synchronous, so an effect can call it (`Thread.isMainThread` is unavailable in async code).
private func isOnMainThread() -> Bool { pthread_main_np() != 0 }

// Declared at file scope, so the interactor and the effect literal in its `body` are nonisolated:
// the effect gets the main actor only from the start phase of the `ViewModel`'s runtime. The same
// literal written in a `@MainActor` test body would be main-actor-isolated by its lexical context
// and would hide a start phase that lost the isolation (an effect task created in a closure nested
// inside `assumeIsolated` starts synchronously but resumes on the global executor).
@Interactor<IsolationProbeState, IsolationProbeAction>
struct IsolationProbeInteractor {
    let clock: TestClock<Duration>
    let log: EffectLog

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .start:
                effects.perform {
                    log.append("preamble main=\(isOnMainThread())")
                    // `TestClock.sleep` is `@concurrent`: the effect hops to the global executor and
                    // must come back. The test ends the sleep by cancelling the effect, because an
                    // `advance` right after the send races the sleeper's registration there.
                    do {
                        try await clock.sleep(for: .seconds(1))
                        log.append("TestClock.sleep returned")
                    } catch {
                        MainActor.assertIsolated("The effect resumed off the main actor after TestClock.sleep")
                        log.append("after TestClock.sleep main=\(isOnMainThread())")
                    }
                    await Task.yield()
                    MainActor.assertIsolated("The effect resumed off the main actor after Task.yield()")
                    log.append("after Task.yield main=\(isOnMainThread())")
                    try effects.modify { $0.isFinished = true }
                }
            }
        }
    }
}

@MainActor
@Suite
struct ViewModelIsolationTests {
    @Test
    func effectFormedInANonisolatedContextResumesOnTheMainActor() async {
        let clock = TestClock()
        let log = EffectLog()
        let viewModel = ViewModel(
            initialState: IsolationProbeState(),
            feature: Feature(interactor: IsolationProbeInteractor(clock: clock, log: log))
        )

        let task = viewModel.sendViewEvent(.start)
        #expect(log.entries == ["preamble main=true"])

        task?.cancel()  // ends the sleep; the effect carries on after it
        await task?.value

        #expect(
            log.entries == [
                "preamble main=true",
                "after TestClock.sleep main=true",
                "after Task.yield main=true",
            ]
        )
        #expect(viewModel.isFinished)
    }
}
