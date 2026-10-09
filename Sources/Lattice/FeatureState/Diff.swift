@MainActor
public func _commitProjectionMember<Root, Value>(
    _ member: ProjectionValueMember<Root, Value>, old: Root, new: Root,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    if member.isDerived {
        _ = registrar.commitDerived(key, coarse: false, areEqual: member.areEqual) {
            new[keyPath: member.keyPath]
        }
    } else if !member.areEqual(old[keyPath: member.keyPath], new[keyPath: member.keyPath]) {
        registrar.invalidate(key)
    }
}

@MainActor
public func _commitProjectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ member: ProjectionChildMember<Root, Child>, old: Root, new: Root,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    if let areEqual = member.areEqual {
        _ = registrar.commitDerived(key, coarse: true, areEqual: areEqual) { new[keyPath: member.keyPath] }
    } else {
        Child._commit(old: old[keyPath: member.keyPath], new: new[keyPath: member.keyPath], registrar: registrar, key: key)
    }
}

@MainActor
public func _commitProjectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ member: ProjectionOptionalMember<Root, Child>, old: Root, new: Root,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    if let areEqual = member.areEqual {
        _ = registrar.commitDerived(key, coarse: true, areEqual: areEqual) { new[keyPath: member.keyPath] }
        return
    }
    switch (old[keyPath: member.keyPath], new[keyPath: member.keyPath]) {
    case (nil, nil): break
    case (let old?, let new?):
        Child._commit(old: old, new: new, registrar: registrar, key: key)
    default:
        registrar.invalidate(prefix: key)
    }
}

/// Generated enum commits invalidate their subtree when the active case changes.
@MainActor
public func _invalidateProjectionSubtree(registrar: FeatureStateRegistrar, key: ProjectionKey) {
    registrar.invalidate(prefix: key)
}
