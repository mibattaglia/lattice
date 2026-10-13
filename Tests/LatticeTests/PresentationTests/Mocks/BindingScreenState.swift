import CasePaths
import Foundation
import Lattice

// A `@FeatureState` enum must be alone in its file (Swift 6.4 crash, unified-feature-state.md §10).
/// A screen with a `@FeatureState` payload (`loaded`) and a plain payload (`failed`).
@CasePathable
@FeatureState
enum BindingScreenState: Equatable, Sendable {
    case loaded(BindingLoadedState)
    case failed(BindingFailure)
}
