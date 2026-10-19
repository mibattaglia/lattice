/// A commit a test shell recorded outside the action under test, waiting for an assertion: an action
/// an effect sent (asserted with `receive`) or a modification an effect made (`action == nil`,
/// asserted with `expect`), with the state right after it.
struct Received<State, Action> {
    /// `nil` for a modification.
    let action: Action?
    let resultingState: State
}
