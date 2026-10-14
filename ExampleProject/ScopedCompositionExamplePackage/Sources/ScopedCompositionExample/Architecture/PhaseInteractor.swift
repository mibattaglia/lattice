import Lattice

@Interactor<PhaseState, PhaseEvent>
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
                // A second Load tap delivers a second `.loaded`; it leaves the loaded payload alone.
                guard case .loading = state else { return .none }
                state = .success(SuccessState())
                return .none

            case .resetTapped:
                state = .loading
                return .none

            case .startTicking:
                // A once-per-second tick stream. Nothing prevents a second start, because an enum
                // state has no storage outside its cases: the root view's `.task` sends this once,
                // and a re-appearing view would start a second stream.
                return .observe {
                    let clock = ContinuousClock()
                    return AsyncStream(unfolding: {
                        try? await clock.sleep(for: .seconds(1))
                        return Task.isCancelled ? nil : .tick
                    })
                }

            case .tick:
                // Only the .active payload counts ticks, so `Tick:` counts the ticks since Start.
                // While a payloadless case (.loading or .idle) is showing, a tick changes nothing.
                guard case .success(var success) = state,
                    case .active(var active) = success.session.telemetry.subphase
                else { return .none }
                active.tick += 1
                success.session.telemetry.subphase = .active(active)
                state = .success(success)
                return .none

            case .success(let action):
                // Late sends after the case deactivated are dropped here, by design: the
                // interactor is the arbiter of whether an action still applies.
                guard case .success(var success) = state else { return .none }
                switch action {
                case .titleChanged(let title):
                    success.title = title
                case .summary(.incremented):
                    success.summary.count += 1
                case .session(.telemetry(.startTapped)):
                    guard case .idle = success.session.telemetry.subphase else { return .none }
                    success.session.telemetry.subphase = .active(ActiveState())
                case .session(.telemetry(.stopTapped)):
                    success.session.telemetry.subphase = .idle
                case .session(.telemetry(.subphase(.active(.noteChanged(let note))))):
                    guard case .active(var active) = success.session.telemetry.subphase else {
                        return .none
                    }
                    active.note = note
                    success.session.telemetry.subphase = .active(active)
                }
                state = .success(success)
                return .none
            }
        }
    }
}
