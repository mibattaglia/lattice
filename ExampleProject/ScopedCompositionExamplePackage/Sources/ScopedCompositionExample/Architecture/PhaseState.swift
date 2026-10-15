import CasePaths
import Foundation
import Lattice

/// The whole state is an enum: a normal exhaustive `switch` over `viewModel.viewState` selects
/// the case, and `scope(state: \.success, action: \.success)` projects the matched payload into
/// a live `ScopedViewModel`. `@CasePathable` supplies the case key paths, and `@FeatureState`
/// carries it onto the generated `ViewState` mirror that views switch over and scope through.
///
/// The success payload is a deep chain of nested `@FeatureState` slices —
/// `Success > Session > Telemetry > Subphase > Active` — with `Summary` as a sibling branch,
/// so the render counters can show exactly which boundaries a change crosses.
@CasePathable
@FeatureState
enum PhaseState: Equatable {
    case loading
    case success(SuccessState)
}
