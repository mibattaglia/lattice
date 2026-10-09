/// Generated mutation identity and filtered member metadata for a value state.
/// Conformance adds no blanket Sendable, Equatable, or actor isolation.
public protocol FeatureStateProtocol: _FeatureStateStructure {
    associatedtype _ViewMembers
    static var _viewMembers: _ViewMembers { get }
}

/// Temporary quarantine for the unconsumed draft projection implementation.
/// T6 removes it with that implementation. `@FeatureState` never generates this
/// conformance, so tracked states cannot enter the old projection path.
public protocol _LegacyFeatureProjectionState {
    associatedtype _ViewMembers

    /// Fresh descriptor metadata; reading it does not access live presentation storage.
    static var _viewMembers: _ViewMembers { get }

    @MainActor
    static func _commit(old: Self, new: Self, registrar: FeatureStateRegistrar, key: ProjectionKey)
}
