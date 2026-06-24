import CasePaths

@CasePathable
enum TimerLeakEvent: Equatable, Sendable {
    case start
    case tick
}
