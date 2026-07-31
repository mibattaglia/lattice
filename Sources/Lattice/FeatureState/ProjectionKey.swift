/// Identifies one view-visible slot in a (possibly nested) feature-state tree.
/// Structurally parallel to `GraphPath`, but keyed by projection members rather than
/// interactor-tree position, and extended per collection element.
public struct ProjectionKey: Hashable {
    enum Component: Hashable {
        case member(AnyKeyPath)  // a _ViewMembers key path
        case element(AnyHashable)  // an Identifiable element id inside a collection
        case structure  // the slot's shape: optional presence / collection membership+order
    }

    var components: [Component] = []

    public init() {}

    public func appending(_ member: AnyKeyPath) -> Self {
        var copy = self
        copy.components.append(.member(member))
        return copy
    }

    func appending(id: AnyHashable) -> Self {
        var copy = self
        copy.components.append(.element(id))
        return copy
    }

    /// The slot's shape key: fired when the slot's shape changes (optional presence flips,
    /// collection membership/order changes) and never by content changes within the slot —
    /// content fires bubble to ancestors, and a shape key is a sibling of the content keys,
    /// not an ancestor.
    var structure: Self {
        var copy = self
        copy.components.append(.structure)
        return copy
    }

    func hasPrefix(_ prefix: Self) -> Bool {
        components.count >= prefix.components.count
            && zip(components, prefix.components).allSatisfy(==)
    }
}
