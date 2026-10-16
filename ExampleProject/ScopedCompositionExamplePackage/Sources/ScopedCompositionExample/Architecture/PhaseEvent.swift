import CasePaths
import Foundation

/// Child actions nest the same way the state slices do:
/// `ActiveAction` ⊂ `SubphaseAction` ⊂ `TelemetryAction` ⊂ `SessionAction` ⊂ `SuccessAction`
/// ⊂ `PhaseEvent`, with `SummaryAction` as a sibling branch under `SuccessAction`.
@CasePathable
enum ActiveAction: Equatable {
    case noteChanged(String)
}

@CasePathable
enum SubphaseAction: Equatable {
    case active(ActiveAction)
}

@CasePathable
enum TelemetryAction: Equatable {
    case startTapped
    case stopTapped
    case subphase(SubphaseAction)
}

@CasePathable
enum SessionAction: Equatable {
    case telemetry(TelemetryAction)
}

@CasePathable
enum SummaryAction: Equatable {
    case incremented
}

/// Actions for the success case's payload, embedded into ``PhaseEvent`` via `.success`.
@CasePathable
enum SuccessAction: Equatable {
    case titleChanged(String)
    case summary(SummaryAction)
    case session(SessionAction)
}

@CasePathable
enum PhaseEvent: Equatable {
    case loadTapped
    case resetTapped
    case startTicking
    case success(SuccessAction)
}
