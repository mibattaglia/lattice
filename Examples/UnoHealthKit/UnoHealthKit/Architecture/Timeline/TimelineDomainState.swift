import CasePaths
import Foundation

@CasePathable
enum TimelineDomainState: Equatable {
    case loading
    case loaded(TimelineData)
    case error(String)
}

struct TimelineData: Equatable {
    let entries: [TimelineEntry]
    let lastUpdated: Date
}
