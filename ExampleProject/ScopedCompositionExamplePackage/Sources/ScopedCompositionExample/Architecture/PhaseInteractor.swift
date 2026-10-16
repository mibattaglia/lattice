import Lattice

@Interactor<PhaseState, PhaseEvent>
struct PhaseInteractor<C: Clock> {
    private let clock: C
    private let loadDuration: C.Duration
    private let tickInterval: C.Duration

    /// - Parameters:
    ///   - loadDuration: How long the fake load takes.
    ///   - tickInterval: The time between two ticks.
    init(clock: C, loadDuration: C.Duration, tickInterval: C.Duration) {
        self.clock = clock
        self.loadDuration = loadDuration
        self.tickInterval = tickInterval
    }

    var body: some InteractorOf<Self> {
        Interact { state, event, effects in
            switch event {
            case .loadTapped:
                // Fake an async load so the .loading -> .success case change is visible. Tapping
                // Load again auto-cancels this load while it sleeps, so the success case comes a
                // full delay after the last tap.
                effects.perform {
                    try await clock.sleep(for: loadDuration)
                    // No `checkCancellation()` here, unlike Search: every load writes the same
                    // case, and the `.loading` guard turns a late commit into a no-op.
                    try effects.modify { state in
                        // A Load tap while loaded leaves the loaded payload alone.
                        guard case .loading = state else { return }
                        state = .success(SuccessState())
                    }
                }

            case .resetTapped:
                state = .loading

            case .startTicking:
                // A once-per-second tick. Sending `.startTicking` again auto-cancels the running
                // ticker, so there is never a second one; the root view's `.task` sends it and
                // cancels the ticker when the view goes away.
                effects.perform {
                    // Runs until cancelled: the sleep then throws, which ends the loop.
                    while true {
                        try await clock.sleep(for: tickInterval)
                        try effects.modify(tick)
                    }
                }

            case .success(let action):
                // Late sends after the case deactivated are dropped here, by design: the
                // interactor is the arbiter of whether an action still applies.
                guard case .success(var success) = state else { return }
                switch action {
                case .titleChanged(let title):
                    success.title = title
                case .summary(.incremented):
                    success.summary.count += 1
                case .session(.telemetry(.startTapped)):
                    guard case .idle = success.session.telemetry.subphase else { return }
                    success.session.telemetry.subphase = .active(ActiveState())
                case .session(.telemetry(.stopTapped)):
                    success.session.telemetry.subphase = .idle
                case .session(.telemetry(.subphase(.active(.noteChanged(let note))))):
                    guard case .active(var active) = success.session.telemetry.subphase else {
                        return
                    }
                    active.note = note
                    success.session.telemetry.subphase = .active(active)
                }
                state = .success(success)
            }
        }
    }

    /// Only the .active payload counts ticks, so `Tick:` counts the ticks since Start. While a
    /// payloadless case (.loading or .idle) is showing, a tick changes nothing.
    private func tick(_ state: inout PhaseState) {
        guard case .success(var success) = state,
            case .active(var active) = success.session.telemetry.subphase
        else { return }
        active.tick += 1
        success.session.telemetry.subphase = .active(active)
        state = .success(success)
    }
}

extension PhaseInteractor where C == ContinuousClock {
    init() {
        self.init(clock: ContinuousClock(), loadDuration: .seconds(1), tickInterval: .seconds(1))
    }
}
