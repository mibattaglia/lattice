import Foundation

struct PendingReceive<State: Sendable, Action: Sendable>: Sendable {
    let action: Action
    let resultingState: State
    let rootScopeID: SendScopeID
}
