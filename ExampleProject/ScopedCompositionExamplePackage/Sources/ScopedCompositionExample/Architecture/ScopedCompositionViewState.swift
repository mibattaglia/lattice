import CasePaths
import Foundation
import Lattice

/// Root view state composed of nested `@ObservableState` slices so scoped children observe
/// exactly their own slice (`App > Dashboard > Header > Badge`, plus a `Footer` sibling).
@ObservableState
struct ScopedCompositionViewState: Equatable, Sendable {
    var dashboard: DashboardState
    var footer: FooterState
}

@ObservableState
struct DashboardState: Equatable, Sendable {
    var header: HeaderState
}

@ObservableState
struct HeaderState: Equatable, Sendable {
    var title: String
    var badge: BadgeState
}

@ObservableState
struct BadgeState: Equatable, Sendable {
    var label: String
    var count: Int
}

@ObservableState
struct FooterState: Equatable, Sendable {
    var status: String
}
