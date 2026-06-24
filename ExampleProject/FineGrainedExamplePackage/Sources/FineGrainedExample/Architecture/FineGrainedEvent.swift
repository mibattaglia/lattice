import CasePaths
import Foundation

@CasePathable
enum FineGrainedEvent: Equatable, Sendable {
    case setTitle(String)
    case bumpCount
    case togglePhase
}
