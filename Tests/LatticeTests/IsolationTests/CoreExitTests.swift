import Foundation
import Testing

@testable import Lattice

@FeatureState
struct ExitProbeState: Equatable {
    var effectRuns = 0
    var sends = 0
}

enum ExitProbeAction {
    case startEffect
    case startNoEffect
}

@Interactor<ExitProbeState, ExitProbeAction>
struct ExitProbeInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            state.sends += 1
            switch action {
            case .startEffect:
                effects.perform { try effects.modify { $0.effectRuns += 1 } }
            case .startNoEffect:
                break
            }
        }
    }
}

#if os(macOS) || os(Linux) || os(Windows)
    /// Starting an effect is the runtime's only dynamic isolation check: `send` creates effect tasks
    /// inside `isolation.assumeIsolated`, which traps off the core's isolation.
    @Suite
    struct CoreExitTests {
        @Test
        func sendThatStartsAnEffectOffTheCoresIsolationTraps() async {
            await #expect(processExitsWith: .failure) {
                let core = Core(
                    isolation: MainActor.shared,
                    initialState: ExitProbeState(),
                    interactor: ExitProbeInteractor().eraseToAnyInteractor(),
                    areStatesEqual: nil
                )
                await Task.detached { _ = core.send(.startEffect) }.value
            }
        }

        /// Control: the same send on the core's isolation starts the effect and exits normally.
        @Test
        func sendThatStartsAnEffectOnTheCoresIsolationRuns() async {
            await #expect(processExitsWith: .success) {
                await MainActor.run {
                    let core = Core(
                        isolation: MainActor.shared,
                        initialState: ExitProbeState(),
                        interactor: ExitProbeInteractor().eraseToAnyInteractor(),
                        areStatesEqual: nil
                    )
                    _ = core.send(.startEffect)
                    precondition(core.committedState.effectRuns == 1)
                }
            }
        }

        /// Current behaviour: a send that starts no effect is not checked at runtime (there is
        /// deliberately no per-send isolation assertion), so the trap above comes from effect start.
        @Test
        func sendThatStartsNoEffectOffTheCoresIsolationIsNotChecked() async {
            await #expect(processExitsWith: .success) {
                let core = Core(
                    isolation: MainActor.shared,
                    initialState: ExitProbeState(),
                    interactor: ExitProbeInteractor().eraseToAnyInteractor(),
                    areStatesEqual: nil
                )
                let sends = await Task.detached {
                    _ = core.send(.startNoEffect)
                    return core.committedState.sends
                }.value
                precondition(sends == 1)
            }
        }
    }
#endif
