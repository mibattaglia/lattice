import IdentifiedCollections

/// A lazily projecting view over a collection of child states. Elements are
/// `Base.Element.ViewState`; indices are the base collection's indices.
public struct ViewStateCollection<Base: RandomAccessCollection>: RandomAccessCollection
where Base.Element: FeatureState {
    @_spi(Lattice) public let _base: Base
    public init(_ base: Base) { _base = base }
    public var startIndex: Base.Index { _base.startIndex }
    public var endIndex: Base.Index { _base.endIndex }
    public func index(after i: Base.Index) -> Base.Index { _base.index(after: i) }
    public func index(before i: Base.Index) -> Base.Index { _base.index(before: i) }
    public subscript(position: Base.Index) -> Base.Element.ViewState { .init(_base[position]) }
}

extension ViewStateCollection {
    /// `IdentifiedArray` lookup. The constraint must name `Element` separately; a
    /// `where Base == IdentifiedArray<ID, Base.Element>` clause is rejected as recursive.
    public subscript<ID: Hashable, Element: FeatureState>(id id: ID) -> Element.ViewState?
    where Base == IdentifiedArray<ID, Element> {
        _base[id: id].map(Element.ViewState.init)
    }
    public var ids: Base.Indices { _base.indices }
}
