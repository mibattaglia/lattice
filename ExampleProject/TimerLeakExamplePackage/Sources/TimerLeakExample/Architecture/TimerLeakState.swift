import Lattice
import Observation

/// The feature's one state, with a nested `@FeatureState` child. The interactor rebuilds
/// `child` wholesale on every tick (assignment, not field mutation), which is
/// exactly the pattern that triggers the content-equal registrar leak.
@FeatureState
struct TimerLeakState: Equatable, Sendable {
    var tickCount: Int = 0
    @Domain var displayedValue: String = "value-0"
    @Domain var isRunning: Bool = false
    var child: TimerChildState = TimerChildState(value: "value-0")
}

@FeatureState
struct TimerChildState: Equatable, Sendable {
    var value: String
    /// A wide subtree of nested `@FeatureState` rows. The child is rebuilt
    /// wholesale every tick, so every content-equal tick orphans one registrar
    /// per row that the view is tracking — the leak rate scales with `rows.count`.
    /// The array lives *inside* the assigned struct on purpose: the
    /// constrained `mutate` overload short-circuits the content-equal child
    /// assignment before the array is ever touched.
    var rows: [TimerRowState]
}

extension TimerChildState {
    /// A child whose `TimerLeakConstants.rowCount` rows all show `value`.
    init(value: String) {
        self.init(
            value: value,
            rows: (0..<TimerLeakConstants.rowCount).map { id in
                TimerRowState(id: id, value: value)
            }
        )
    }
}

@FeatureState
struct TimerRowState: Equatable, Identifiable, Sendable {
    let id: Int
    var value: String
}

/// Number of nested rows rebuilt each tick and re-rendered each frame by the
/// TimelineView. The leak rate scales with this. Rows reuse their view identity
/// (no destroy/recreate churn), so this can be higher than the .id-recreation
/// approach — ~500 rows leaks visibly while staying renderable at 60fps. Drop it
/// if frames are skipped, raise it if growth is too slow.
enum TimerLeakConstants {
    static let rowCount = 500
}
