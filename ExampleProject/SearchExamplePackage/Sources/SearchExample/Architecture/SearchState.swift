import CasePaths
import Foundation
import Lattice

// A `@FeatureState` enum must be alone in its file (Swift 6.4 crash, unified-feature-state.md §10).
/// NB: this being an enum is probably overkill, but I wanted to show off the
/// power of observing enums and binding to enums in this demo.
@CasePathable
@FeatureState
enum SearchState: Equatable, Sendable {
    case noResults
    case results(ResultState)
}
