import CasePaths
import Foundation
import Lattice

@CasePathable
@FeatureState
enum MatchPhase: Equatable {
    case waiting
    case playing(PlayerState)
    case finished(winner: String, rounds: Int)
    case overtime(PlayerState?)
    case shootout([PlayerState], String)
    var isWaiting: Bool { if case .waiting = self { true } else { false } }
    @Domain var maxRounds: Int { 3 }
}
