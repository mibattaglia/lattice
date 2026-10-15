import Foundation
import Lattice

/// The feature's one state, composed of nested `@FeatureState` slices so scoped children
/// observe exactly their own slice (`App > Dashboard > Header > Badge`, plus a `Footer` sibling).
@FeatureState
struct ScopedCompositionState: Equatable {
    var dashboard = DashboardState()
    var footer = FooterState()
}

@FeatureState
struct DashboardState: Equatable {
    var header = HeaderState()
}

@FeatureState
struct HeaderState: Equatable {
    var title = "Dashboard"
    var badge = BadgeState()
}

@FeatureState
struct BadgeState: Equatable {
    var label = "Badge"
    var count = 0
}

@FeatureState
struct FooterState: Equatable {
    var status = "Ready"
}
