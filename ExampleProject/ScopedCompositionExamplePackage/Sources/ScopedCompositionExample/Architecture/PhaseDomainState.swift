import Foundation

/// Flat domain state; the view-state reducer projects it into the nested phase enum.
struct PhaseDomainState: Equatable, Sendable {
    var isLoaded: Bool = false
    var isTicking: Bool = false
    var isActive: Bool = false
    var title: String = "Success"
    var count: Int = 0
    var sessionName: String = "Live sync"
    var status: String = "Connected"
    var tick: Int = 0
    var note: String = ""
}
