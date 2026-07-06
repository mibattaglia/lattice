import Foundation

/// Flat domain state; the view-state reducer projects it into nested slices.
struct ScopedCompositionDomainState: Equatable, Sendable {
    var title: String = "Dashboard"
    var badgeLabel: String = "Badge"
    var badgeCount: Int = 0
    var footerStatus: String = "Ready"
}
