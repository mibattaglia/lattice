import CasePaths
import Foundation

/// Child actions nest the same way the view-state slices do:
/// `BadgeAction` ⊂ `HeaderAction` ⊂ `DashboardAction` ⊂ `ScopedCompositionEvent`.
@CasePathable
enum BadgeAction: Equatable, Sendable {
    case labelChanged(String)
    case incremented
}

@CasePathable
enum HeaderAction: Equatable, Sendable {
    case titleChanged(String)
    case badge(BadgeAction)
}

@CasePathable
enum DashboardAction: Equatable, Sendable {
    case header(HeaderAction)
}

@CasePathable
enum ScopedCompositionEvent: Equatable, Sendable {
    case dashboard(DashboardAction)
    case setFooter(String)
}
