import Foundation
import Lattice

@Interactor<TimerLeakState, TimerLeakEvent>
struct TimerLeakInteractor<C: Clock> {
    private let clock: C
    /// Tick interval. ~20ms ≈ 50 Hz.
    private let tickInterval: C.Duration

    init(clock: C, tickInterval: C.Duration) {
        self.clock = clock
        self.tickInterval = tickInterval
    }

    var body: some InteractorOf<Self> {
        Interact { _, event, effects in
            switch event {
            case .start:
                // The ticker. Sending `.start` again auto-cancels the running ticker, so there is
                // never more than one; the view's `.task` cancels it when the view goes away.
                effects.perform {
                    // Runs until cancelled: the sleep then throws, which ends the loop.
                    while true {
                        try await clock.sleep(for: tickInterval)
                        try effects.modify(tick)
                    }
                }
            }
        }
    }

    private func tick(_ state: inout TimerLeakState) {
        state.tickCount += 1
        // Leaf value changes only every 100 ticks; on all other ticks
        // the rebuilt child is content-equal -> forces the leak path.
        if state.tickCount % 100 == 0 {
            state.displayedValue = "value-\(state.tickCount / 100)"
        }
        // Wholesale child rebuild on every tick (assignment, not field
        // mutation). This is the whole point of the demo. The child carries
        // `rowCount` nested @FeatureState rows, so one content-equal
        // assignment orphans that many registrars per frame.
        state.child = TimerChildState(value: state.displayedValue)
    }
}

extension TimerLeakInteractor where C == ContinuousClock {
    init(tickInterval: Duration = .milliseconds(20)) {
        self.init(clock: ContinuousClock(), tickInterval: tickInterval)
    }
}
