import IdentifiedCollections
import OrderedCollections

/// Projection over an identified collection of feature states.
@MainActor
public struct CollectionProjection<Element>
where Element: FeatureStateProtocol & Identifiable & Equatable {
    let read: () -> IdentifiedArrayOf<Element>
    let registrar: FeatureStateRegistrar
    let key: ProjectionKey

    /// Structural reads register the collection's shape key: any insert/remove/reorder
    /// fires it; element content changes do not (they bubble to the collection's own
    /// subtree key, which only explicitly coarse readers register).
    public var ids: OrderedSet<Element.ID> {
        registrar.access(key.structure)
        return read().ids
    }

    public var count: Int {
        registrar.access(key.structure)
        return read().count
    }

    public var isEmpty: Bool {
        registrar.access(key.structure)
        return read().isEmpty
    }

    /// Per-element projection. `nil` when the id is no longer present — row views can be
    /// asked to render transiently after a removal, before the structural ping propagates.
    /// Registers the shape key (membership is shape), never the collection's subtree key.
    public subscript(id id: Element.ID) -> FeatureProjection<Element>? {
        registrar.access(key.structure)
        guard read()[id: id] != nil else { return nil }
        return FeatureProjection<Element>(
            read: { read()[id: id]! },
            registrar: registrar,
            key: key.appending(id: id)
        )
    }
}
