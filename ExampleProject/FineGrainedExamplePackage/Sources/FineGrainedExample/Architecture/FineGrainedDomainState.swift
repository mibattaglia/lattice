import Foundation

struct FineGrainedDomainState: Equatable, Sendable {
    var title: String = "Hello"
    var count: Int = 0
    var phaseActive: Bool = false
}
