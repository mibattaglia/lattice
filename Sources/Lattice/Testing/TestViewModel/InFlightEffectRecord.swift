import Foundation

struct InFlightEffectRecord<Action: Sendable>: Sendable {
    let id: LegacyEffectID
    let rootScopeID: SendScopeID
}
