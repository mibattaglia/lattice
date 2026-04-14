struct BufferedAction<Action: Sendable>: Sendable {
    let action: Action
    let source: ActionSource
    let rootScopeID: SendScopeID
}
