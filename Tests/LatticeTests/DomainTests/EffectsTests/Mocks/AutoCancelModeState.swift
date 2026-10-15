import CasePaths
import Foundation
import Lattice

/// The enum state of the case-path auto-cancel tests: the child is active only in `.active`.
@CasePathable
@FeatureState
enum AutoCancelModeState: Equatable {
    case active(AutoCancelChildState)
    case idle
}
