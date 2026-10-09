/// Identifies a visible member, structural slot, or identified row in a state tree.
public struct ProjectionKey: Hashable {
    enum Component: Hashable {
        case member(AnyKeyPath)
        case element(AnyHashable)
        case structure
    }

    var components: [Component] = []

    init() {}

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
