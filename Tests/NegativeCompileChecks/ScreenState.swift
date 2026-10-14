import CasePaths
import Foundation
import Lattice

@CasePathable
@FeatureState
enum ScreenState: Equatable, Sendable {
    case loading
    case loaded(LoadedState)
}
