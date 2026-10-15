import CasePaths
import Foundation
import Lattice

/// The enum state of the case-path `When` tests.
@CasePathable
@FeatureState
enum LoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded(CounterState)
}
