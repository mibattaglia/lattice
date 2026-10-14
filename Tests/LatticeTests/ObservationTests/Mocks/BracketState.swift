import Foundation
import Lattice

@FeatureState
indirect enum BracketState: Equatable {
    case seed(Int)
    case match(BracketState, BracketState)
}
