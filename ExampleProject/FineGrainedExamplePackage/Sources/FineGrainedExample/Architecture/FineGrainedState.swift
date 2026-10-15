import CasePaths
import Foundation
import Lattice

/// The feature's one state. Every member is observed on its own, so mutating one member does
/// not invalidate observers of the others, and the visible computed `phase` re-renders when the
/// hidden `phaseActive` it derives from changes.
@FeatureState
struct FineGrainedState: Equatable {
    var title = "Hello"
    var count = 0
    @Domain var phaseActive = false

    /// The phase views show, derived from the domain-only `phaseActive` flag.
    var phase: FineGrainedPhase { phaseActive ? .active("Active!") : .idle }
}

@CasePathable
@dynamicMemberLookup
enum FineGrainedPhase: Equatable {
    case idle
    case active(String)
}
