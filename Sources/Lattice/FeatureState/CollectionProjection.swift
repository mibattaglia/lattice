import IdentifiedCollections
import OrderedCollections

/// Filtered, identity-keyed access to feature rows.
@MainActor
public struct CollectionProjection<Element: _LegacyFeatureProjectionState & Identifiable & Equatable> {
    let read: () -> (value: IdentifiedArrayOf<Element>, isLive: Bool)
    let registrar: FeatureStateRegistrar
    let key: ProjectionKey

    private func structure() -> IdentifiedArrayOf<Element> {
        let snapshot = read()
        if snapshot.isLive { registrar.access(key.structure) }
        return snapshot.value
    }

    public var ids: OrderedSet<Element.ID> { structure().ids }
    public var count: Int { structure().count }
    public var isEmpty: Bool { structure().isEmpty }

    /// Fresh absent reads return nil. A held row serves its creation snapshot while
    /// absent and resolves the current row if the same ID reappears.
    public subscript(id id: Element.ID) -> FeatureProjection<Element>? {
        guard let initial = structure()[id: id] else { return nil }
        return FeatureProjection(
            resolve: {
                let snapshot = read()
                let current = snapshot.value[id: id]
                if snapshot.isLive, current == nil { registrar.access(key.structure) }
                return (current ?? initial, snapshot.isLive && current != nil)
            }, registrar: registrar, key: key.appending(id: id)
        )
    }
}
