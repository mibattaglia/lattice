struct RootScopeState: Sendable {
    var bufferedActionCount = 0
    var inFlightEffectIDs: Set<LegacyEffectID> = []

    var isQuiescent: Bool {
        bufferedActionCount == 0 && inFlightEffectIDs.isEmpty
    }
}
