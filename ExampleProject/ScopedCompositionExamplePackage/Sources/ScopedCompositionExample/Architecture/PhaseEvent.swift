import CasePaths
import Foundation

/// Child actions nest the same way the view-state slices do:
/// `ActiveAction` ⊂ `SubphaseAction` ⊂ `TelemetryAction` ⊂ `SessionAction` ⊂ `SuccessAction`
/// ⊂ `PhaseEvent`, with `SummaryAction` as a sibling branch under `SuccessAction`.
@CasePathable
enum ActiveAction: Equatable, Sendable {
    case noteChanged(String)
}

@CasePathable
enum SubphaseAction: Equatable, Sendable {
    case active(ActiveAction)
}

@CasePathable
enum TelemetryAction: Equatable, Sendable {
    case startTapped
    case stopTapped
    case subphase(SubphaseAction)
}

@CasePathable
enum SessionAction: Equatable, Sendable {
    case telemetry(TelemetryAction)
}

@CasePathable
enum SummaryAction: Equatable, Sendable {
    case incremented
}

/// Actions for the success case's payload, embedded into ``PhaseEvent`` via `.success`.
@CasePathable
enum SuccessAction: Equatable, Sendable {
    case titleChanged(String)
    case summary(SummaryAction)
    case session(SessionAction)
}

@CasePathable
enum PhaseEvent: Equatable, Sendable {
    case loadTapped
    case loaded
    case resetTapped
    case startTicking
    case tick
    case success(SuccessAction)
}
