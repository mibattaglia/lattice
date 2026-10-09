import IdentifiedCollections

/// Read-only, filtered access to a feature state's visible members.
@MainActor
@dynamicMemberLookup
public struct FeatureProjection<State: _LegacyFeatureProjectionState> {
    let read: () -> (value: State, isLive: Bool)
    let registrar: FeatureStateRegistrar
    let key: ProjectionKey

    init(read: @escaping () -> State, registrar: FeatureStateRegistrar = FeatureStateRegistrar()) {
        self.init(resolve: { (read(), true) }, registrar: registrar, key: ProjectionKey())
    }

    init(resolve: @escaping () -> (State, Bool), registrar: FeatureStateRegistrar, key: ProjectionKey) {
        self.read = resolve
        self.registrar = registrar
        self.key = key
    }

    public subscript<Value>(
        dynamicMember member: KeyPath<State._ViewMembers, ProjectionValueMember<State, Value>>
    ) -> Value {
        let descriptor = State._viewMembers[keyPath: member]
        let snapshot = read()
        guard snapshot.isLive else { return snapshot.value[keyPath: descriptor.keyPath] }
        let memberKey = key.appending(member)
        if descriptor.isDerived {
            return registrar.derived(memberKey) { snapshot.value[keyPath: descriptor.keyPath] }
        }
        registrar.access(memberKey)
        return snapshot.value[keyPath: descriptor.keyPath]
    }

    public subscript<Child: _LegacyFeatureProjectionState>(
        dynamicMember member: KeyPath<State._ViewMembers, ProjectionChildMember<State, Child>>
    ) -> FeatureProjection<Child> {
        let descriptor = State._viewMembers[keyPath: member]
        let childKey = key.appending(member)
        let resolve: () -> (Child, Bool) = {
            let snapshot = read()
            let value: Child
            if snapshot.isLive, descriptor.areEqual != nil {
                value = registrar.derived(childKey) { snapshot.value[keyPath: descriptor.keyPath] }
            } else {
                value = snapshot.value[keyPath: descriptor.keyPath]
            }
            return (value, snapshot.isLive)
        }
        _ = resolve() // Seed/register a computed parent even before descendant reads.
        return FeatureProjection<Child>(resolve: resolve, registrar: registrar, key: childKey)
    }

    public subscript<Child: _LegacyFeatureProjectionState>(
        dynamicMember member: KeyPath<State._ViewMembers, ProjectionOptionalMember<State, Child>>
    ) -> FeatureProjection<Child>? {
        let descriptor = State._viewMembers[keyPath: member]
        let childKey = key.appending(member)
        let resolve: () -> (Child?, Bool) = {
            let snapshot = read()
            if snapshot.isLive {
                registrar.access(childKey.structure)
                if descriptor.areEqual != nil {
                    return (registrar.derived(childKey) { snapshot.value[keyPath: descriptor.keyPath] }, true)
                }
            }
            return (snapshot.value[keyPath: descriptor.keyPath], snapshot.isLive)
        }
        guard let initial = resolve().0 else { return nil }
        return FeatureProjection<Child>(
            resolve: {
                let current = resolve()
                return (current.0 ?? initial, current.1 && current.0 != nil)
            }, registrar: registrar, key: childKey
        )
    }

    public subscript<Element: _LegacyFeatureProjectionState & Identifiable & Equatable>(
        dynamicMember member: KeyPath<State._ViewMembers, ProjectionCollectionMember<State, Element>>
    ) -> CollectionProjection<Element> {
        let descriptor = State._viewMembers[keyPath: member]
        let childKey = key.appending(member)
        let resolve: () -> (IdentifiedArrayOf<Element>, Bool) = {
            let snapshot = read()
            if snapshot.isLive, descriptor.isDerived {
                return (registrar.derived(childKey) { snapshot.value[keyPath: descriptor.keyPath] }, true)
            }
            return (snapshot.value[keyPath: descriptor.keyPath], snapshot.isLive)
        }
        _ = resolve()
        return CollectionProjection(read: resolve, registrar: registrar, key: childKey)
    }
}
