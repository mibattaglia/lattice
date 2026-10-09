import IdentifiedCollections

/// Generated descriptors keep raw extraction internal. Model entry points accept
/// only paths into this namespace, never paths into the raw state.
public struct FeatureStateValueMember<Root, Value> {
    let read: (Root) -> Value
}

public struct FeatureStateChildMember<Root, Child: FeatureStateProtocol> {
    let keyPath: KeyPath<Root, Child>
    let read: (Root) -> Child
}

public struct FeatureStateOptionalMember<Root, Child: FeatureStateProtocol> {
    // Scope creation preserves native container dependencies; commit refresh
    // uses the non-observing extraction separately.
    let access: (Root) -> Child?
    let read: (Root) -> Child?
}

public struct FeatureStateRowsMember<Root, Row: FeatureStateProtocol & Identifiable> {
    let read: (Root) -> [Row]
}

/// Generated only when the member namespace exposes `id`. Result adaptation
/// additionally checks that it is a leaf of the row's actual ID type.
public protocol _FeatureStateIdentityMembers {
    associatedtype _IdentityMember
    var id: _IdentityMember { get }
}

@_disfavoredOverload
public func _featureStateMember<Root, Value>(
    _ keyPath: KeyPath<Root, Value>, read: @escaping (Root) -> Value
) -> FeatureStateValueMember<Root, Value> {
    FeatureStateValueMember(read: { $0[keyPath: keyPath] })
}

public func _featureStateMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, Child>, read: @escaping (Root) -> Child
) -> FeatureStateChildMember<Root, Child> {
    FeatureStateChildMember(keyPath: keyPath, read: read)
}

public func _featureStateMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, Child?>, read: @escaping (Root) -> Child?
) -> FeatureStateOptionalMember<Root, Child> {
    FeatureStateOptionalMember(access: { $0[keyPath: keyPath] }, read: read)
}

/// Used by generated enum metadata, without a raw payload getter on the state.
public func _featureStateCaseMember<Root, Child: FeatureStateProtocol>(
    _ read: @escaping (Root) -> Child?
) -> FeatureStateOptionalMember<Root, Child> {
    FeatureStateOptionalMember(access: read, read: read)
}

@_disfavoredOverload
public func _featureStateCaseMember<Root, Value: _FeatureStateScalarPayload>(
    _ read: @escaping (Root) -> Value?
) -> FeatureStateValueMember<Root, Value?> {
    FeatureStateValueMember(read: read)
}

public struct _UnsupportedFeatureStateCaseMember<Root, Value> {}

@_disfavoredOverload
public func _featureStateCaseMember<Root, Value>(
    _ read: @escaping (Root) -> Value?
) -> _UnsupportedFeatureStateCaseMember<Root, Value> { _UnsupportedFeatureStateCaseMember() }

@available(*, unavailable, message: "annotated feature enum cases require one tracked payload or supported scalar; use one tracked payload struct for other cases")
public func _validateFeatureStateMember<Root, Value>(_ member: _UnsupportedFeatureStateCaseMember<Root, Value>) {}

public func _featureStateMember<Root, Row: FeatureStateProtocol & Identifiable>(
    _ keyPath: KeyPath<Root, [Row]>, read: @escaping (Root) -> [Row]
) -> FeatureStateRowsMember<Root, Row>
where Row._ViewMembers: _FeatureStateIdentityMembers,
    Row._ViewMembers._IdentityMember == FeatureStateValueMember<Row, Row.ID> {
    // List reads must retain the stored getter's legitimate dependencies.
    FeatureStateRowsMember(read: { $0[keyPath: keyPath] })
}

public func _featureStateMember<Root, Row: FeatureStateProtocol & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Row>>, read: @escaping (Root) -> IdentifiedArrayOf<Row>
) -> FeatureStateRowsMember<Root, Row>
where Row._ViewMembers: _FeatureStateIdentityMembers,
    Row._ViewMembers._IdentityMember == FeatureStateValueMember<Row, Row.ID> {
    FeatureStateRowsMember(read: { Array($0[keyPath: keyPath]) })
}

@_disfavoredOverload
public func _featureStateComputedMember<Root, Value>(
    _ keyPath: KeyPath<Root, Value>
) -> FeatureStateValueMember<Root, Value> {
    FeatureStateValueMember(read: { $0[keyPath: keyPath] })
}

public func _featureStateComputedMember<Root, Row: FeatureStateProtocol & Identifiable>(
    _ keyPath: KeyPath<Root, [Row]>
) -> FeatureStateRowsMember<Root, Row>
where Row._ViewMembers: _FeatureStateIdentityMembers,
    Row._ViewMembers._IdentityMember == FeatureStateValueMember<Row, Row.ID> {
    FeatureStateRowsMember(read: { $0[keyPath: keyPath] })
}

public func _featureStateComputedMember<Root, Row: FeatureStateProtocol & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Row>>
) -> FeatureStateRowsMember<Root, Row>
where Row._ViewMembers: _FeatureStateIdentityMembers,
    Row._ViewMembers._IdentityMember == FeatureStateValueMember<Row, Row.ID> {
    FeatureStateRowsMember(read: { Array($0[keyPath: keyPath]) })
}

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, Child>
) -> _UnsupportedComputedFeatureStateMember<Root, Child> { _UnsupportedComputedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, Child?>
) -> _UnsupportedComputedFeatureStateMember<Root, Child?> { _UnsupportedComputedFeatureStateMember() }

/// Recognized unsupported containers cannot become raw leaves via contextual typing.
public struct _UnsupportedFeatureStateMember<Root, Value> {}

public func _featureStateMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child]>, read: @escaping (Root) -> [Child]
) -> _UnsupportedFeatureStateMember<Root, [Child]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?]>, read: @escaping (Root) -> [Child?]
) -> _UnsupportedFeatureStateMember<Root, [Child?]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child]?>, read: @escaping (Root) -> [Child]?
) -> _UnsupportedFeatureStateMember<Root, [Child]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?]?>, read: @escaping (Root) -> [Child?]?
) -> _UnsupportedFeatureStateMember<Root, [Child?]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Child>?>, read: @escaping (Root) -> IdentifiedArrayOf<Child>?
) -> _UnsupportedFeatureStateMember<Root, IdentifiedArrayOf<Child>?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child>>, read: @escaping (Root) -> Set<Child>
) -> _UnsupportedFeatureStateMember<Root, Set<Child>> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child?>>, read: @escaping (Root) -> Set<Child?>
) -> _UnsupportedFeatureStateMember<Root, Set<Child?>> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child>?>, read: @escaping (Root) -> Set<Child>?
) -> _UnsupportedFeatureStateMember<Root, Set<Child>?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child?>?>, read: @escaping (Root) -> Set<Child?>?
) -> _UnsupportedFeatureStateMember<Root, Set<Child?>?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Key: Hashable, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Key: Child]>, read: @escaping (Root) -> [Key: Child]
) -> _UnsupportedFeatureStateMember<Root, [Key: Child]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Key: Hashable, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Key: Child?]>, read: @escaping (Root) -> [Key: Child?]
) -> _UnsupportedFeatureStateMember<Root, [Key: Child?]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Key: Hashable, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Key: Child]?>, read: @escaping (Root) -> [Key: Child]?
) -> _UnsupportedFeatureStateMember<Root, [Key: Child]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Key: Hashable, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Key: Child?]?>, read: @escaping (Root) -> [Key: Child?]?
) -> _UnsupportedFeatureStateMember<Root, [Key: Child?]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child: Value]>, read: @escaping (Root) -> [Child: Value]
) -> _UnsupportedFeatureStateMember<Root, [Child: Value]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child?: Value]>, read: @escaping (Root) -> [Child?: Value]
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child: Value]?>, read: @escaping (Root) -> [Child: Value]?
) -> _UnsupportedFeatureStateMember<Root, [Child: Value]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child?: Value]?>, read: @escaping (Root) -> [Child?: Value]?
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child: Value]>, read: @escaping (Root) -> [Child: Value]
) -> _UnsupportedFeatureStateMember<Root, [Child: Value]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?: Value]>, read: @escaping (Root) -> [Child?: Value]
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child: Value]?>, read: @escaping (Root) -> [Child: Value]?
) -> _UnsupportedFeatureStateMember<Root, [Child: Value]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?: Value]?>, read: @escaping (Root) -> [Child?: Value]?
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child: Value?]>, read: @escaping (Root) -> [Child: Value?]
) -> _UnsupportedFeatureStateMember<Root, [Child: Value?]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?: Value?]>, read: @escaping (Root) -> [Child?: Value?]
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value?]> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child: Value?]?>, read: @escaping (Root) -> [Child: Value?]?
) -> _UnsupportedFeatureStateMember<Root, [Child: Value?]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?: Value?]?>, read: @escaping (Root) -> [Child?: Value?]?
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value?]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child]>
) -> _UnsupportedFeatureStateMember<Root, [Child]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?]>
) -> _UnsupportedFeatureStateMember<Root, [Child?]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child]?>
) -> _UnsupportedFeatureStateMember<Root, [Child]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?]?>
) -> _UnsupportedFeatureStateMember<Root, [Child?]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Child>?>
) -> _UnsupportedFeatureStateMember<Root, IdentifiedArrayOf<Child>?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child>>
) -> _UnsupportedFeatureStateMember<Root, Set<Child>> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child?>>
) -> _UnsupportedFeatureStateMember<Root, Set<Child?>> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child>?>
) -> _UnsupportedFeatureStateMember<Root, Set<Child>?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child?>?>
) -> _UnsupportedFeatureStateMember<Root, Set<Child?>?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Key: Hashable, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Key: Child]>
) -> _UnsupportedFeatureStateMember<Root, [Key: Child]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Key: Hashable, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Key: Child?]>
) -> _UnsupportedFeatureStateMember<Root, [Key: Child?]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Key: Hashable, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Key: Child]?>
) -> _UnsupportedFeatureStateMember<Root, [Key: Child]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Key: Hashable, Child: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Key: Child?]?>
) -> _UnsupportedFeatureStateMember<Root, [Key: Child?]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child: Value]>
) -> _UnsupportedFeatureStateMember<Root, [Child: Value]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child?: Value]>
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child: Value]?>
) -> _UnsupportedFeatureStateMember<Root, [Child: Value]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child?: Value]?>
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child: Value]>
) -> _UnsupportedFeatureStateMember<Root, [Child: Value]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?: Value]>
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child: Value]?>
) -> _UnsupportedFeatureStateMember<Root, [Child: Value]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?: Value]?>
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child: Value?]>
) -> _UnsupportedFeatureStateMember<Root, [Child: Value?]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?: Value?]>
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value?]> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child: Value?]?>
) -> _UnsupportedFeatureStateMember<Root, [Child: Value?]?> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Child: FeatureStateProtocol & Hashable, Value: FeatureStateProtocol>(
    _ keyPath: KeyPath<Root, [Child?: Value?]?>
) -> _UnsupportedFeatureStateMember<Root, [Child?: Value?]?> { _UnsupportedFeatureStateMember() }

public func _featureStateMember<Root, Row: FeatureStateProtocol & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Row>>, read: @escaping (Root) -> IdentifiedArrayOf<Row>
) -> _UnsupportedFeatureStateMember<Root, IdentifiedArrayOf<Row>> { _UnsupportedFeatureStateMember() }

public func _featureStateComputedMember<Root, Row: FeatureStateProtocol & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Row>>
) -> _UnsupportedFeatureStateMember<Root, IdentifiedArrayOf<Row>> { _UnsupportedFeatureStateMember() }

public struct _UnsupportedComputedFeatureStateMember<Root, Value> {}

// Validation is separate from category inference: an unavailable factory alone
// lets Swift choose a less-specialized raw-leaf overload. Here metadata has an
// already-fixed descriptor type, with no contextual raw-child fallback.
public func _validateFeatureStateMember<Root, Value>(_ member: FeatureStateValueMember<Root, Value>) {}
public func _validateFeatureStateMember<Root, Child>(_ member: FeatureStateChildMember<Root, Child>) {}
public func _validateFeatureStateMember<Root, Child>(_ member: FeatureStateOptionalMember<Root, Child>) {}
public func _validateFeatureStateMember<Root, Row>(_ member: FeatureStateRowsMember<Root, Row>) {}

@available(*, unavailable, message: "unsupported tracked container; use an identified row collection with a view-visible leaf id or an explicit optional parent scope")
public func _validateFeatureStateMember<Root, Value>(_ member: _UnsupportedFeatureStateMember<Root, Value>) {}

@available(*, unavailable, message: "computed tracked children require a stored child and an explicit scope")
public func _validateFeatureStateMember<Root, Value>(_ member: _UnsupportedComputedFeatureStateMember<Root, Value>) {}
