import CasePaths
import Foundation
import Lattice

@CasePathable
@FeatureState
enum PhaseState: Equatable, Sendable {
    case loading
    case success(SuccessState)
}
