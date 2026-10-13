import CasePaths
import Foundation
import Lattice

// A `@FeatureState` enum must be alone in its file (Swift 6.4 crash, unified-feature-state.md §10).
/// A nested sub-phase enum inside the success payload, case-scoped via the
/// `ScopedViewModel.scope(state:action:)` case overload: inner case changes re-render only
/// the inner switch subtree, never the root switch.
@CasePathable
@FeatureState
enum SubphaseState: Equatable, Sendable {
    case idle
    case active(ActiveState)
}
