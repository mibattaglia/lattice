import Foundation
import Lattice

// A `@FeatureState` enum must be alone in its file (Swift 6.4 crash, unified-feature-state.md §10).
@FeatureState
enum RootPhaseViewState: Equatable, Sendable, DefaultValueProvider {
    static let defaultValue = Self.loading
    case loading
    case content(String)
}
