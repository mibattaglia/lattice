import Lattice
import Observation

/// View state with a nested `@ObservableState` child. The reducer rebuilds
/// `child` wholesale on every tick (assignment, not field mutation), which is
/// exactly the pattern that triggers the content-equal registrar leak described
/// in specs/observable-state-identity-preserving-merge.md.
@ObservableState
struct TimerLeakViewState: Equatable {
    var tickCount: Int = 0
    var child: TimerChildViewState = TimerChildViewState(value: "value-0", rows: [])
}

@ObservableState
struct TimerChildViewState: Equatable {
    var value: String
    /// A wide subtree of nested `@ObservableState` rows. The child is rebuilt
    /// wholesale every tick, so every content-equal tick orphans one registrar
    /// per row that the view is tracking — the leak rate scales with `rows.count`.
    /// The array lives *inside* the assigned struct on purpose: the fix's
    /// constrained `mutate` overload short-circuits the content-equal child
    /// assignment before the array is ever touched.
    var rows: [TimerRowViewState]
}

@ObservableState
struct TimerRowViewState: Equatable, Identifiable {
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
