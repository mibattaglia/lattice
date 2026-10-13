import Foundation
import Lattice

// A `@FeatureState` enum must be alone in its file (Swift 6.4 crash, unified-feature-state.md §10).
@FeatureState
enum RootPhaseState: Equatable, Sendable {
    case loading
    case content(String)
}
