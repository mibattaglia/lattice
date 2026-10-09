/// Instruments mutable stored inputs and generates a filtered model-member
/// namespace. Hidden inputs are still tracked. Computed getters execute normally;
/// identified filter/sort results are adapted to read-only model handles.
///
/// Visible members require explicit types. Ordinary nested tracked children use
/// explicit scopes. Attached macros cannot discover unrelated extension members.
@attached(member, names: named(_ViewMembers), named(_viewMembers), named(_featureStateIdentity), arbitrary)
@attached(memberAttribute)
@attached(extension, conformances: FeatureStateProtocol)
public macro FeatureState() =
    #externalMacro(module: "LatticeMacros", type: "FeatureStateMacro")

/// Hides a property from model reads, without changing its Swift visibility or
/// excluding its mutable storage from observation.
@attached(peer)
public macro Domain() =
    #externalMacro(module: "LatticeMacros", type: "DomainMacro")

/// Implementation detail of `@FeatureState`.
@attached(accessor, names: named(init), named(get), named(set), named(_modify))
@attached(peer, names: prefixed(_feature_))
public macro _FeatureStateTrackedProperty() =
    #externalMacro(module: "LatticeMacros", type: "FeatureStateTrackedMacro")
