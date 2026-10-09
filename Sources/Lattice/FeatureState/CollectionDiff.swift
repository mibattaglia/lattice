import IdentifiedCollections

@MainActor
public func _commitProjectionMember<Root, Element: _LegacyFeatureProjectionState & Identifiable & Equatable>(
    _ member: ProjectionCollectionMember<Root, Element>, old: Root, new: Root,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    if member.isDerived {
        if let transition = registrar.commitDerived(key, coarse: true, areEqual: member.areEqual, compute: { new[keyPath: member.keyPath] }),
            let previous = transition.old {
            for id in previous.ids where transition.new[id: id] == nil {
                registrar.removeSignals(prefix: key.appending(id: id))
            }
        }
        return
    }
    let before = old[keyPath: member.keyPath]
    let after = new[keyPath: member.keyPath]
    if before.ids != after.ids {
        registrar.invalidate(key.structure)
        for id in before.ids where after[id: id] == nil {
            registrar.removeSignals(prefix: key.appending(id: id))
        }
    }
    for row in after {
        guard let previous = before[id: row.id], !member.rowsEqual(previous, row) else { continue }
        // Row equality must compare every input affecting presentation, including
        // @Domain inputs of computed outputs. It is not the root assertion comparator.
        Element._commit(old: previous, new: row, registrar: registrar, key: key.appending(id: row.id))
    }
}
