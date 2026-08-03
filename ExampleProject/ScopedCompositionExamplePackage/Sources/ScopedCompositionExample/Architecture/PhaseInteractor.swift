import Lattice

@Interactor<PhaseState, PhaseEvent>
struct PhaseInteractor {
    /// Named identity for the tick stream: `isRunning` replaces the old `isTicking` flag,
    /// and the id gives the long-lived effect an explicit handle.
    @EffectID var ticker

    var body: some InteractorOf<Self> {
        Interact { [ticker] state, event, effects in
            switch event {
            case .loadTapped:
                // Fake an async load so the .loading -> .success case change is visible.
                // The effect re-enters by mutating state directly — no `.loaded` action.
                effects.perform { effectState in
                    try? await ContinuousClock().sleep(for: .seconds(1))
                    try effectState.modify { state in
                        state = .success(SuccessState())
                    }
                }

            case .resetTapped:
                state = .loading

            case .startTicking:
                guard !ticker.isRunning else { return }
                // Once-per-second tick stream. Ticks that land while no `.active` sub-phase
                // is showing mutate nothing — a no-change commit fires no observers.
                effects.perform(id: ticker) { effectState in
                    let clock = ContinuousClock()
                    while !Task.isCancelled {
                        try await clock.sleep(for: .seconds(1))
                        try effectState.modify { state in
                            guard case .success(var success) = state,
                                case .active(var active) = success.session.telemetry.subphase
                            else { return }
                            active.tick += 1
                            success.session.telemetry.subphase = .active(active)
                            state = .success(success)
                        }
                    }
                }

            case .success(let action):
                // Late sends after the case deactivated are dropped here, by design: `When`
                // isn't used for this demo's action routing, so the interactor is the
                // arbiter of whether an action still applies.
                guard case .success(var success) = state else { return }
                switch action {
                case .titleChanged(let title):
                    success.title = title
                case .summary(.incremented):
                    success.summary.count += 1
                case .session(.telemetry(.startTapped)):
                    success.session.telemetry.subphase = .active(ActiveState())
                case .session(.telemetry(.stopTapped)):
                    success.session.telemetry.subphase = .idle
                case .session(.telemetry(.subphase(.active(.noteChanged(let note))))):
                    guard case .active(var active) = success.session.telemetry.subphase
                    else { return }
                    active.note = note
                    success.session.telemetry.subphase = .active(active)
                }
                state = .success(success)
            }
        }
    }
}
