struct RootScopeState: Sendable {
    var bufferedActionCount = 0
    var inFlightEffectIDs: Set<EffectID> = []

    var isQuiescent: Bool {
        bufferedActionCount == 0 && inFlightEffectIDs.isEmpty
    }
}
