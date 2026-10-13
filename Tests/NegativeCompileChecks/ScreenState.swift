import CasePaths
import Foundation
import Lattice

// A `@FeatureState` enum must be alone in its file (Swift 6.4 crash, unified-feature-state.md §10).
@CasePathable
@FeatureState
enum ScreenState: Equatable, Sendable {
    case loading
    case loaded(LoadedState)
}
