import Lattice

/// One `@FeatureState` type: the raw tick count is `@Domain` (interactor-only), and the
/// visible `displayedValue` changes only every 100 ticks — the commit diff fires its
/// observers only then, even though the timer commits ~50 times per second.
@FeatureState
struct TimerLeakState: Equatable {
    @Domain var tickCount: Int = 0
    @Domain var isRunning: Bool = false
    var displayedValue: String = "value-0"
}

/// Number of rows rendered each frame by the TimelineView. Every row reads
/// `displayedValue`; the per-member diff means none of them re-render on the ~50 Hz
/// commits whose visible output is unchanged.
enum TimerLeakConstants {
    static let rowCount = 500
}
