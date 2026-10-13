import Foundation
import Lattice

/// The feature's one state, composed of nested `@FeatureState` slices so scoped children
/// observe exactly their own slice (`App > Dashboard > Header > Badge`, plus a `Footer` sibling).
@FeatureState
struct ScopedCompositionState: Equatable, Sendable {
    var dashboard: DashboardState = DashboardState()
    var footer: FooterState = FooterState()
}

@FeatureState
struct DashboardState: Equatable, Sendable {
    var header: HeaderState = HeaderState()
}

@FeatureState
struct HeaderState: Equatable, Sendable {
    var title: String = "Dashboard"
    var badge: BadgeState = BadgeState()
}

@FeatureState
struct BadgeState: Equatable, Sendable {
    var label: String = "Badge"
    var count: Int = 0
}

@FeatureState
struct FooterState: Equatable, Sendable {
    var status: String = "Ready"
}
