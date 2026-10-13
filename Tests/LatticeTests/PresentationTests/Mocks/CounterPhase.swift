import CasePaths
import Foundation
import Lattice

// A `@FeatureState` enum must be alone in its file (Swift 6.4 crash, unified-feature-state.md §10).
@FeatureState
@CasePathable
enum CounterPhase: Equatable, Sendable {
    case idle
    case active(CounterPhasePayload)
}
