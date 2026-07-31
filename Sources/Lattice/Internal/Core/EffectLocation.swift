/// Identifies the effect "slot" within one tree node that owns a task bucket.
///
/// The first `perform` for a `(path, location)` during one update replaces the in-flight
/// bucket; subsequent `perform`s in the same update track alongside.
enum EffectLocation: Hashable {
    /// Auto-replacement slot identified by the source location of the `perform` call.
    case callSite(fileID: String, line: UInt, column: UInt)
    /// Explicit slot owned by an `@EffectID`.
    case id(AnyHashable)
}

/// Full key for one task bucket: which node, which slot.
struct TaskKey: Hashable {
    let path: GraphPath
    let location: EffectLocation
}
