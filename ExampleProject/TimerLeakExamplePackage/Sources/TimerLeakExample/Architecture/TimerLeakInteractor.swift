import Foundation
import Lattice

@Interactor<TimerLeakDomainState, TimerLeakEvent>
struct TimerLeakInteractor: Sendable {
    /// Tick interval. ~20ms ≈ 50 Hz, inside the spec's 30–60 Hz window.
    private let tickInterval: Duration

    init(tickInterval: Duration = .milliseconds(20)) {
        self.tickInterval = tickInterval
    }

    var body: some InteractorOf<Self> {
        Interact { [tickInterval] state, event in
            switch event {
            case .start:
                guard !state.isRunning else { return .none }
                state.isRunning = true
                return .observe {
                    let clock = ContinuousClock()
                    return AsyncStream(unfolding: {
                        try? await clock.sleep(for: tickInterval)
                        return Task.isCancelled ? nil : .tick
                    })
                }

            case .tick:
                state.tickCount += 1
                // Leaf value changes only every 100 ticks; on all other ticks
                // the rebuilt child is content-equal -> forces the leak path.
                if state.tickCount % 100 == 0 {
                    state.displayedValue = "value-\(state.tickCount / 100)"
                }
                return .none
            }
        }
    }
}
