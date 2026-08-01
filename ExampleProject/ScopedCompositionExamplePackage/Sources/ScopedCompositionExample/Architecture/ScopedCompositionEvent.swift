import CasePaths
import Foundation

/// Child actions nest the same way the view-state slices do:
/// `BadgeAction` ⊂ `HeaderAction` ⊂ `DashboardAction` ⊂ `ScopedCompositionEvent`.
@CasePathable
enum BadgeAction: Equatable {
    case labelChanged(String)
    case incremented
}

@CasePathable
enum HeaderAction: Equatable {
    case titleChanged(String)
    case badge(BadgeAction)
}

@CasePathable
enum DashboardAction: Equatable {
    case header(HeaderAction)
}

@CasePathable
enum ScopedCompositionEvent: Equatable {
    case dashboard(DashboardAction)
    case setFooter(String)
}
