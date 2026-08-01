import CasePaths
import Foundation
import Lattice

/// Root state composed of nested `@FeatureState` slices so scoped children observe exactly
/// their own slice (`App > Dashboard > Header > Badge`, plus a `Footer` sibling). One type is
/// both the model and the view contract — the old flat domain state and the reducer that
/// projected it into these slices are gone.
@FeatureState
struct ScopedCompositionState: Equatable {
    var dashboard: DashboardState = DashboardState()
    var footer: FooterState = FooterState()
}

@FeatureState
struct DashboardState: Equatable {
    var header: HeaderState = HeaderState()
}

@FeatureState
struct HeaderState: Equatable {
    var title: String = "Dashboard"
    var badge: BadgeState = BadgeState()
}

@FeatureState
struct BadgeState: Equatable {
    var label: String = "Badge"
    var count: Int = 0
}

@FeatureState
struct FooterState: Equatable {
    var status: String = "Ready"
}
