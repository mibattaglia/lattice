struct ActionTransition<State: Sendable, Action: Sendable>: Sendable {
    let action: Action
    let source: ActionSource
    let previousState: State
    let currentState: State
    let emission: Emission<Action>
    let rootScopeID: SendScopeID
}
