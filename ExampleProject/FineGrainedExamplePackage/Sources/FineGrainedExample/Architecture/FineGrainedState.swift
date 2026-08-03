import Foundation
import Lattice

/// One `@FeatureState` type: the demo is now a direct showcase of per-member projection
/// granularity — each subview reads one visible member, and the commit diff pokes only the
/// members whose value (or derived output) actually changed.
@FeatureState
struct FineGrainedState: Equatable {
    @Domain var phaseActive: Bool = false

    var title: String = "Hello"
    var count: Int = 0

    /// Derived view output over a `@Domain` member: diffed by output, so observers fire
    /// only on an actual idle/active flip.
    var phaseLabel: String? {
        phaseActive ? "Active!" : nil
    }
}
