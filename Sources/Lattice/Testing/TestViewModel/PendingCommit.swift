/// One unasserted re-entry into the core, captured by the test commit strategy.
///
/// No `Sendable`, no constraints — everything is confined to the test host's isolation
/// (MainActor). Presence-flip cancellation never produces a commit of its own (it runs inside
/// the funnel of the mutation that flipped the presence), so there is no cancellation case.
enum PendingCommit<DomainState, Action> {
    /// An `effectState.modify` commit: the state as committed.
    case mutation(resulting: DomainState)

    /// An `effectState.send` re-entry: the action, and the state after its update phase.
    case action(Action, resulting: DomainState)

    var resultingState: DomainState {
        switch self {
        case .mutation(let state), .action(_, resulting: let state):
            return state
        }
    }
}
