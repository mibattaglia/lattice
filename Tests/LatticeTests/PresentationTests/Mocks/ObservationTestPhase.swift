import CasePaths
import Foundation
import Lattice

@FeatureState
@CasePathable
enum ObservationTestPhase: Equatable, Sendable {
    case idle
    case active(ObservationTestPayload)
}
