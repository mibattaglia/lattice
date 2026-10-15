import CasePaths
import Foundation
import Lattice

/// The enum state of the case-scoped child tests: the child is active only in `.active`.
@CasePathable
@FeatureState
enum GatedModeState: Equatable {
    case active(GatedChildState)
    case inactive
}
