import Foundation
import Lattice

@FeatureState
enum RootPhaseState: Equatable, Sendable {
    case loading
    case content(String)
}
