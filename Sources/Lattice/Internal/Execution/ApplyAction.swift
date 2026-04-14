extension ActionTransition {
    @MainActor
    static func apply(
        _ action: Action,
        source: ActionSource,
        rootScopeID: SendScopeID,
        to state: inout State,
        using interactor: AnyInteractor<State, Action>
    ) -> Self {
        let previousState = state
        let emission = interactor.interact(state: &state, action: action)

        return .init(
            action: action,
            source: source,
            previousState: previousState,
            currentState: state,
            emission: emission,
            rootScopeID: rootScopeID
        )
    }
}
