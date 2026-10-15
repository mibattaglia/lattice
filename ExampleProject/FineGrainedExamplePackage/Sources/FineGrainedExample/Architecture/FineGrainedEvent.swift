import CasePaths
import Foundation

@CasePathable
enum FineGrainedEvent: Equatable {
    case setTitle(String)
    case bumpCount
    case togglePhase
}
