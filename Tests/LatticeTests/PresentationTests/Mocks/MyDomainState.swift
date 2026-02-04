import CasePaths
import Foundation

@CasePathable
enum MyDomainState: Equatable {
    case loading
    case error(code: Int)
    case success(Content)

    struct Content: Equatable {
        var count: Int
        var timestamp: TimeInterval
        var isLoading: Bool
    }
}
