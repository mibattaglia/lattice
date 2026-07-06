import Lattice

@Interactor<PhaseDomainState, PhaseEvent>
struct PhaseInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .loadTapped:
                // Fake an async load so the .loading -> .success case change is visible.
                return .perform {
                    try? await ContinuousClock().sleep(for: .seconds(1))
                    return .loaded
                }

            case .loaded:
                state.isLoaded = true
                return .none

            case .resetTapped:
                state.isLoaded = false
                return .none

            case .startTicking:
                guard !state.isTicking else { return .none }
                state.isTicking = true
                // Once-per-second tick stream: the unrelated-reduce driver that makes the
                // _$inert fix visible while a payloadless case (.loading or .idle) is active,
                // and the deep-leaf driver while the .active sub-phase is showing.
                return .observe {
                    let clock = ContinuousClock()
                    return AsyncStream(unfolding: {
                        try? await clock.sleep(for: .seconds(1))
                        return Task.isCancelled ? nil : .tick
                    })
                }

            case .tick:
                state.tick += 1
                return .none

            case .success(let action):
                // Late sends after the case deactivated are dropped here, by design: the
                // interactor is the arbiter of whether an action still applies.
                guard state.isLoaded else { return .none }
                switch action {
                case .titleChanged(let title):
                    state.title = title
                case .summary(.incremented):
                    state.count += 1
                case .session(.telemetry(.startTapped)):
                    state.isActive = true
                case .session(.telemetry(.stopTapped)):
                    state.isActive = false
                case .session(.telemetry(.subphase(.active(.noteChanged(let note))))):
                    guard state.isActive else { return .none }
                    state.note = note
                }
                return .none
            }
        }
    }
}
