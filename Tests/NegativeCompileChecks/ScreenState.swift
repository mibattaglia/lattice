import CasePaths
import Foundation
import Lattice

@CasePathable
@FeatureState
enum ScreenState: Equatable {
    case loading
    case loaded(LoadedState)
}
