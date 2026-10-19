import CasePaths
import Foundation
import Lattice

/// A nested sub-phase enum inside the success payload, case-scoped via the
/// `ScopedViewModel.scope(state:action:)` case overload: inner case changes re-render only
/// the inner switch subtree, never the root switch.
@CasePathable
@FeatureState
enum SubphaseState: Equatable {
    case idle
    case active(ActiveState)
}
