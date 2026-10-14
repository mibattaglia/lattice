import CasePaths
import Foundation
import Lattice

@FeatureState
@CasePathable
enum CounterPhase: Equatable, Sendable {
    case idle
    case active(CounterPhasePayload)
}
