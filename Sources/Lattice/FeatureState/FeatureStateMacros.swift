/// Generates a filtered member namespace and commit diff for an ordinary struct
/// or enum state. It adds no Sendable, Equatable, or whole-state actor isolation.
///
/// Visible properties require explicit type annotations. `@Domain`, private,
/// and fileprivate getters are excluded without changing their Swift access.
/// Synchronous get-only computed outputs are cached by the host after first use.
/// Attached macros cannot include properties declared in separate extensions.
@attached(member, names: named(_ViewMembers), named(_viewMembers), named(_commit), arbitrary)
@attached(extension, conformances: FeatureStateProtocol)
public macro FeatureState() =
    #externalMacro(module: "LatticeMacros", type: "FeatureStateMacro")

/// Excludes a property from its enclosing `@FeatureState` projection.
/// Does not change access to the raw domain value.
@attached(peer)
public macro Domain() =
    #externalMacro(module: "LatticeMacros", type: "DomainMacro")
