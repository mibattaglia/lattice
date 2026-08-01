import CasePaths
import Foundation
import Lattice

/// The whole feature state is an enum: the root view branches on the active case, and
/// `scope`/`scopeIfActive` project the matched payload into a live `ScopedViewModel` via the
/// generated case accessors. `@CasePathable` supplies the case key paths that `when` and the
/// action embedding use.
///
/// The success payload is a deep chain of nested `@FeatureState` slices —
/// `Success > Session > Telemetry > Subphase > Active` — with `Summary` as a sibling branch,
/// so the render counters can show exactly which boundaries a change crosses. There is no
/// separate view-state tree and no reducer: this one type is both the model and the view
/// contract, and the commit diff recurses per member.
@FeatureState
@CasePathable
enum PhaseState: Equatable {
    case loading
    case success(SuccessState)
}

@FeatureState
struct SuccessState: Equatable {
    var title: String = "Success"
    var summary: SummaryState = SummaryState()
    var session: SessionState = SessionState()
}

@FeatureState
struct SummaryState: Equatable {
    var count: Int = 0
}

@FeatureState
struct SessionState: Equatable {
    var name: String = "Live sync"
    var telemetry: TelemetryState = TelemetryState()
}

@FeatureState
struct TelemetryState: Equatable {
    var status: String = "Connected"
    var subphase: SubphaseState = .idle
}

/// A nested sub-phase enum inside the success payload, case-scoped via the
/// `ScopedViewModel` case overloads: inner case changes re-render only the inner branch,
/// never the root.
@FeatureState
@CasePathable
enum SubphaseState: Equatable {
    case idle
    case active(ActiveState)
}

@FeatureState
struct ActiveState: Equatable {
    var tick: Int = 0
    var note: String = ""
}
