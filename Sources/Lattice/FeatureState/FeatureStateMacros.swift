/// Instruments mutable stored inputs and generates a filtered model-member
/// namespace. Hidden inputs are still tracked. Computed getters execute normally;
/// identified filter/sort results are adapted to read-only model handles.
///
/// Visible members require explicit types. Ordinary nested tracked children and
/// tracked enum payloads use explicit scopes. Single scalar enum payloads are
/// optional leaf reads; their enum boundary observes value and case changes.
/// Attached macros cannot discover unrelated extension members.
///
/// Stored `willSet`/`didSet` observers run on the generated backing property,
/// with the original value types for their parameters. A notifying setter signals
/// before those observers. Scalar `_modify` signals before yielding; tracked
/// aggregate replacement signals after yielding, before the stored observers.
/// Equal scalar setters still run property observers without notifying.
///
/// Like TCA26's value-observation accessors, this is not full unannotated Swift
/// stored-property semantics: assigning the public property inside its own
/// `didSet` re-enters its accessors and can invoke `didSet` again. Observer bodies
/// retain their name lookup; they are not rewritten to bypass those accessors.
@attached(member, names: named(_ViewMembers), named(_viewMembers), named(_featureStateIdentity), named(_featureStateLocation))
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
