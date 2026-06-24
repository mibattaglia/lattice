import CasePaths
import Foundation
import Lattice

/// Root view state composed of independent slices so that mutating one slice in the reducer
/// does not invalidate observers of the others.
@ObservableState
struct FineGrainedViewState: Equatable, Sendable {
    var header: FineGrainedHeader
    var footer: FineGrainedFooter
    var phase: FineGrainedPhase
}

@ObservableState
struct FineGrainedHeader: Equatable, Sendable {
    var title: String
}

@ObservableState
struct FineGrainedFooter: Equatable, Sendable {
    var count: Int
}

@CasePathable
@ObservableState
@dynamicMemberLookup
enum FineGrainedPhase: Equatable, Sendable {
    case idle
    case active(String)
}
