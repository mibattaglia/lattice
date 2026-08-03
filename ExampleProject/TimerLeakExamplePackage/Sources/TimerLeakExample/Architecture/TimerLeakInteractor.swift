import Foundation
import Lattice

@Interactor<TimerLeakState, TimerLeakEvent>
struct TimerLeakInteractor {
    /// Tick interval. ~20ms ≈ 50 Hz, inside the spec's 30–60 Hz window.
    private let tickInterval: Duration

    init(tickInterval: Duration = .milliseconds(20)) {
        self.tickInterval = tickInterval
    }

    var body: some InteractorOf<Self> {
        Interact { [tickInterval] state, event, effects in
            switch event {
            case .start:
                guard !state.isRunning else { return }
                state.isRunning = true
                // Long-lived timer stream: a `for`-style loop inside one effect. Each
                // `modify` runs the commit funnel; observers of `displayedValue` are poked
                // only on the ticks where the derived output actually changes.
                effects.perform { effectState in
                    let clock = ContinuousClock()
                    while !Task.isCancelled {
                        try await clock.sleep(for: tickInterval)
                        try effectState.modify { state in
                            state.tickCount += 1
                            // Visible value changes only every 100 ticks; all other
                            // commits are visible no-ops for the rows.
                            if state.tickCount % 100 == 0 {
                                state.displayedValue = "value-\(state.tickCount / 100)"
                            }
                        }
                    }
                }
            }
        }
    }
}
