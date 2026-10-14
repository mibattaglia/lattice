import CasePaths
import Foundation
import Lattice

/// A screen with a `@FeatureState` payload (`loaded`) and a plain payload (`failed`).
@CasePathable
@FeatureState
enum BindingScreenState: Equatable, Sendable {
    case loaded(BindingLoadedState)
    case failed(BindingFailure)
}
