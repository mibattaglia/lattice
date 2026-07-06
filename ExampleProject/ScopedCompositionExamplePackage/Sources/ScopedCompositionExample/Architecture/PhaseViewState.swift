import CasePaths
import Foundation
import Lattice

/// The whole view state is an enum: a normal exhaustive `switch` selects the case, and
/// `scope(state: \.success, action: \.success)` projects the matched payload into a live
/// `ScopedViewModel`. `@CasePathable` supplies the case key paths (`@ObservableState` does
/// not add them).
///
/// The success payload is a deep chain of nested `@ObservableState` slices —
/// `Success > Session > Telemetry > Subphase > Active` — with `Summary` as a sibling branch,
/// so the render counters can show exactly which boundaries a change crosses.
@CasePathable
@ObservableState
enum PhaseViewState: Equatable, Sendable {
    case loading
    case success(SuccessViewState)
}

@ObservableState
struct SuccessViewState: Equatable, Sendable {
    var title: String
    var summary: SummaryViewState
    var session: SessionViewState
}

@ObservableState
struct SummaryViewState: Equatable, Sendable {
    var count: Int
}

@ObservableState
struct SessionViewState: Equatable, Sendable {
    var name: String
    var telemetry: TelemetryViewState
}

@ObservableState
struct TelemetryViewState: Equatable, Sendable {
    var status: String
    var subphase: SubphaseViewState
}

/// A nested sub-phase enum inside the success payload, case-scoped via the
/// `ScopedViewModel.scope(state:action:)` case overload: inner case changes re-render only
/// the inner switch subtree, never the root switch.
@CasePathable
@ObservableState
enum SubphaseViewState: Equatable, Sendable {
    case idle
    case active(ActiveViewState)
}

@ObservableState
struct ActiveViewState: Equatable, Sendable {
    var tick: Int
    var note: String
}
