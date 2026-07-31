/// Structural identity of a node in the static interactor tree.
///
/// An ordered component list with an incrementally maintained FNV-1a hash, so hashing is O(1)
/// regardless of tree depth. Effect task storage is keyed by `GraphPath`, and transition
/// detection cancels buckets by path prefix, so `starts(with:)` and cheap hashing are the two
/// operations that matter.
public struct GraphPath: Hashable {
    private var components: [Component] = []
    private var _hashValue: UInt32 = 2_166_136_261  // FNV-1a offset basis

    enum Component: Hashable {
        case keyPath(AnyKeyPath)
        case id(AnyHashable)
    }

    public init() {}

    mutating func append(_ keyPath: AnyKeyPath) {
        _hashValue = (_hashValue ^ UInt32(truncatingIfNeeded: keyPath.hashValue)) &* 16_777_619
        components.append(.keyPath(keyPath))
    }

    mutating func append(id: AnyHashable) {
        _hashValue = ((_hashValue ^ 1) ^ UInt32(truncatingIfNeeded: id.hashValue)) &* 16_777_619
        components.append(.id(id))
    }

    func appending(_ keyPath: AnyKeyPath) -> GraphPath {
        var path = self
        path.append(keyPath)
        return path
    }

    func appending(id: AnyHashable) -> GraphPath {
        var path = self
        path.append(id: id)
        return path
    }

    /// True when `self` is `prefix` or a descendant of it. The transition-detection and
    /// remount primitive.
    func starts(with prefix: GraphPath) -> Bool {
        components.starts(with: prefix.components)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs._hashValue == rhs._hashValue && lhs.components == rhs.components
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(_hashValue)
    }
}
