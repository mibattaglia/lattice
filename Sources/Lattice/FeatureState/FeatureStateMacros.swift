/// Flattens the domain-state → view-state split into a single annotated state type.
///
/// Attach to a struct or enum. Every member is view-visible unless marked `@Domain` or
/// `private`. Generates the `_ViewMembers` key-path namespace, the `_viewKeyPaths` map, the
/// `_derivedMembers` set, and the `_commit(old:new:registrar:key:)` diff (plus enum case
/// accessors), and adds a `FeatureStateProtocol` conformance.
///
/// ```swift
/// @FeatureState
/// struct SearchState {
///     @Domain var rawResults: [SearchResult] = []   // interactor-only
///     var query: String = ""                        // view-visible, diffed by ==
///     var subtitle: String {                        // derived view output
///         "\(rawResults.count) results"
///     }
/// }
/// ```
@attached(
    member, names: named(_ViewMembers), named(_viewKeyPaths), named(_derivedMembers),
    named(_commit), arbitrary)
@attached(extension, conformances: FeatureStateProtocol)
public macro FeatureState() =
    #externalMacro(module: "LatticeMacros", type: "FeatureStateMacro")

/// Marks a member of a `@FeatureState` type as interactor-only: excluded from the view
/// projection and never diffed. Marker only; expansion is empty — `@FeatureState` reads it
/// during its own expansion.
@attached(peer)
public macro Domain() =
    #externalMacro(module: "LatticeMacros", type: "DomainMacro")
