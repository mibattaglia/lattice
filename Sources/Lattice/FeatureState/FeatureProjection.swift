import IdentifiedCollections

/// The read surface. Generic over the state type; per-type shape comes from the generated
/// `_ViewMembers` namespace, so `@Domain`/private members are unreachable at compile time.
/// The same overload-ranking trick as `_diff` decides whether a member reads as a value,
/// chains as a child projection, or exposes a collection projection.
///
/// Chaining registers no interior keys when the child projection is **bound** before its
/// members are read; inline chained reads degrade to a coarse subtree read (see the leaf
/// subscript note below).
@MainActor
@dynamicMemberLookup
public struct FeatureProjection<State: FeatureStateProtocol> {
    let read: () -> State
    let registrar: FeatureStateRegistrar
    let key: ProjectionKey

    // Leaf values: register access, then serve. Derived members come from the registrar's
    // cache (computing and seeding on first read); stored members read through committed
    // state — one key-path read is already minimal, so they have no cache.
    //
    // Inline chained reads (`projection.child.title`) resolve HERE, not through the child
    // subscript below: the constraint solver prefers the one-lookup raw-value read over the
    // two-lookup chain whenever the trailing hop is this (disfavored) subscript, and no
    // `@_disfavoredOverload` placement can reverse that. The registered `memberKey` is then
    // the child's interior subtree key, so such reads are coarse-but-correct: fires anywhere
    // under the child bubble to it. Per-member granularity (and cache-served derived reads)
    // requires binding the child projection first (`let child = projection.child`), which
    // picks the child subscript. Nested derived members read inline this way compute from
    // committed state directly and bypass the derivation cache.
    @_disfavoredOverload
    public subscript<Value: Equatable>(
        dynamicMember member: KeyPath<State._ViewMembers, Value>
    ) -> Value {
        let memberKey = key.appending(member)
        // The macro generates both sides of the map; the cast cannot fail.
        let stateKeyPath = State._viewKeyPaths[member] as! KeyPath<State, Value>
        if State._derivedMembers.contains(member) {
            return registrar.derived(memberKey) { read()[keyPath: stateKeyPath] }
        }
        registrar.access(memberKey)
        return read()[keyPath: stateKeyPath]
    }

    // Nested feature states chain as child projections. Note: chaining registers nothing.
    public subscript<Child: FeatureStateProtocol>(
        dynamicMember member: KeyPath<State._ViewMembers, Child>
    ) -> FeatureProjection<Child> {
        let stateKeyPath = State._viewKeyPaths[member] as! KeyPath<State, Child>
        return FeatureProjection<Child>(
            read: { read()[keyPath: stateKeyPath] },
            registrar: registrar,
            key: key.appending(member)
        )
    }

    // Optional feature states (optional stored members; enum case accessors):
    // registers the slot's shape key, then chains when present.
    public subscript<Child: FeatureStateProtocol>(
        dynamicMember member: KeyPath<State._ViewMembers, Child?>
    ) -> FeatureProjection<Child>? {
        let childKey = key.appending(member)
        registrar.access(childKey.structure)  // presence flips fire this; content changes do not
        let stateKeyPath = State._viewKeyPaths[member] as! KeyPath<State, Child?>
        guard read()[keyPath: stateKeyPath] != nil else { return nil }
        return FeatureProjection<Child>(
            read: { read()[keyPath: stateKeyPath]! },
            registrar: registrar,
            key: childKey
        )
    }

    // Identified collections of feature states.
    public subscript<Element>(
        dynamicMember member: KeyPath<State._ViewMembers, IdentifiedArrayOf<Element>>
    ) -> CollectionProjection<Element>
    where Element: FeatureStateProtocol & Identifiable & Equatable {
        let stateKeyPath =
            State._viewKeyPaths[member] as! KeyPath<State, IdentifiedArrayOf<Element>>
        return CollectionProjection(
            read: { read()[keyPath: stateKeyPath] },
            registrar: registrar,
            key: key.appending(member)
        )
    }
}
