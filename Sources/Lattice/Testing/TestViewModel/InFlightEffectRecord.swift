import Foundation

struct InFlightEffectRecord<Action: Sendable>: Sendable {
    let id: EffectID
    let rootScopeID: SendScopeID
}
