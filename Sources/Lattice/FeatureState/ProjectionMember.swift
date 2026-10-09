import IdentifiedCollections

/// A descriptor for one explicitly exposed Equatable value.
public struct ProjectionValueMember<Root, Value> {
    let keyPath: KeyPath<Root, Value>
    let isDerived: Bool
    let areEqual: (Value, Value) -> Bool
}

/// A filtered child descriptor, never a raw child value.
public struct ProjectionChildMember<Root, Child: _LegacyFeatureProjectionState> {
    let keyPath: KeyPath<Root, Child>
    let areEqual: ((Child, Child) -> Bool)?
}

/// A filtered optional child, including generated enum case accessors.
public struct ProjectionOptionalMember<Root, Child: _LegacyFeatureProjectionState> {
    let keyPath: KeyPath<Root, Child?>
    let areEqual: ((Child?, Child?) -> Bool)?
}

/// Identified feature rows; stored rows are diffed by identity.
public struct ProjectionCollectionMember<Root, Element: _LegacyFeatureProjectionState & Identifiable & Equatable> {
    let keyPath: KeyPath<Root, IdentifiedArrayOf<Element>>
    let isDerived: Bool
    let areEqual: (IdentifiedArrayOf<Element>, IdentifiedArrayOf<Element>) -> Bool
    let rowsEqual: (Element, Element) -> Bool
}

// Descriptor selection and Equatable capture remain in the ordinary nonisolated
// context. MainActor reads/commits need no potentially isolated generic witness.
@_disfavoredOverload
public func _projectionMember<Root, Value: Equatable>(
    _ keyPath: KeyPath<Root, Value>
) -> ProjectionValueMember<Root, Value> {
    ProjectionValueMember(keyPath: keyPath, isDerived: false, areEqual: { $0 == $1 })
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, Child>
) -> ProjectionChildMember<Root, Child> {
    ProjectionChildMember(keyPath: keyPath, areEqual: nil)
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, Child?>
) -> ProjectionOptionalMember<Root, Child> {
    ProjectionOptionalMember(keyPath: keyPath, areEqual: nil)
}

public func _projectionMember<Root, Element: _LegacyFeatureProjectionState & Identifiable & Equatable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Element>>
) -> ProjectionCollectionMember<Root, Element> {
    ProjectionCollectionMember(keyPath: keyPath, isDerived: false, areEqual: { $0 == $1 }, rowsEqual: { $0 == $1 })
}

@_disfavoredOverload
public func _derivedProjectionMember<Root, Value: Equatable>(
    _ keyPath: KeyPath<Root, Value>
) -> ProjectionValueMember<Root, Value> {
    ProjectionValueMember(keyPath: keyPath, isDerived: true, areEqual: { $0 == $1 })
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Equatable>(
    _ keyPath: KeyPath<Root, Child>
) -> ProjectionChildMember<Root, Child> {
    ProjectionChildMember(keyPath: keyPath, areEqual: { $0 == $1 })
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Equatable>(
    _ keyPath: KeyPath<Root, Child?>
) -> ProjectionOptionalMember<Root, Child> {
    ProjectionOptionalMember(keyPath: keyPath, areEqual: { $0 == $1 })
}

public func _derivedProjectionMember<Root, Element: _LegacyFeatureProjectionState & Identifiable & Equatable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Element>>
) -> ProjectionCollectionMember<Root, Element> {
    ProjectionCollectionMember(keyPath: keyPath, isDerived: true, areEqual: { $0 == $1 }, rowsEqual: { $0 == $1 })
}

@available(*, unavailable, message: "computed feature outputs must be Equatable; add Equatable or '@Domain'")
public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, Child>
) -> ProjectionChildMember<Root, Child> { fatalError() }

@available(*, unavailable, message: "computed feature outputs must be Equatable; add Equatable or '@Domain'")
public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, Child?>
) -> ProjectionOptionalMember<Root, Child> { fatalError() }

@available(*, unavailable, message: "view-visible leaf outputs must be Equatable; add Equatable or '@Domain'")
public func _projectionMember<Root, Value>(_ keyPath: KeyPath<Root, Value>) -> ProjectionValueMember<Root, Value> { fatalError() }

@available(*, unavailable, message: "view-visible leaf outputs must be Equatable; add Equatable or '@Domain'")
public func _derivedProjectionMember<Root, Value>(_ keyPath: KeyPath<Root, Value>) -> ProjectionValueMember<Root, Value> { fatalError() }

/// A rejected standard container of feature values. Generated commits diagnose it
/// instead of letting contextual typing expose a feature as an opaque raw leaf.
public struct UnsupportedFeatureContainerMember<Root, Value> {}

@available(*, unavailable, message: "standard containers of feature states are unsupported; use stored IdentifiedArrayOf feature rows or '@Domain'")
@MainActor
public func _commitProjectionMember<Root, Value>(
    _ member: UnsupportedFeatureContainerMember<Root, Value>, old: Root, new: Root,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) { fatalError() }

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child]>
) -> UnsupportedFeatureContainerMember<Root, [Child]> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child?]>
) -> UnsupportedFeatureContainerMember<Root, [Child?]> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child]?>
) -> UnsupportedFeatureContainerMember<Root, [Child]?> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child?]?>
) -> UnsupportedFeatureContainerMember<Root, [Child?]?> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child>>
) -> UnsupportedFeatureContainerMember<Root, Set<Child>> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child?>>
) -> UnsupportedFeatureContainerMember<Root, Set<Child?>> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child>?>
) -> UnsupportedFeatureContainerMember<Root, Set<Child>?> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child?>?>
) -> UnsupportedFeatureContainerMember<Root, Set<Child?>?> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, ID: Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child]>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child]> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, ID: Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child?]>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child?]> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, ID: Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child]?>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child]?> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, ID: Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child?]?>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child?]?> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Child>>
) -> UnsupportedFeatureContainerMember<Root, IdentifiedArrayOf<Child>> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Child>?>
) -> UnsupportedFeatureContainerMember<Root, IdentifiedArrayOf<Child>?> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child]>
) -> UnsupportedFeatureContainerMember<Root, [Child]> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child?]>
) -> UnsupportedFeatureContainerMember<Root, [Child?]> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child]?>
) -> UnsupportedFeatureContainerMember<Root, [Child]?> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child?]?>
) -> UnsupportedFeatureContainerMember<Root, [Child?]?> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child>>
) -> UnsupportedFeatureContainerMember<Root, Set<Child>> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child?>>
) -> UnsupportedFeatureContainerMember<Root, Set<Child?>> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child>?>
) -> UnsupportedFeatureContainerMember<Root, Set<Child>?> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable>(
    _ keyPath: KeyPath<Root, Set<Child?>?>
) -> UnsupportedFeatureContainerMember<Root, Set<Child?>?> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, ID: Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child]>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child]> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, ID: Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child?]>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child?]> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, ID: Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child]?>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child]?> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, ID: Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child?]?>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child?]?> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Child>>
) -> UnsupportedFeatureContainerMember<Root, IdentifiedArrayOf<Child>> {
    UnsupportedFeatureContainerMember()
}

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Identifiable>(
    _ keyPath: KeyPath<Root, IdentifiedArrayOf<Child>?>
) -> UnsupportedFeatureContainerMember<Root, IdentifiedArrayOf<Child>?> {
    UnsupportedFeatureContainerMember()
}

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child: Value]>
) -> UnsupportedFeatureContainerMember<Root, [Child: Value]> { UnsupportedFeatureContainerMember() }

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child?: Value]>
) -> UnsupportedFeatureContainerMember<Root, [Child?: Value]> { UnsupportedFeatureContainerMember() }

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child: Value]?>
) -> UnsupportedFeatureContainerMember<Root, [Child: Value]?> { UnsupportedFeatureContainerMember() }

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child?: Value]?>
) -> UnsupportedFeatureContainerMember<Root, [Child?: Value]?> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child: Value]>
) -> UnsupportedFeatureContainerMember<Root, [Child: Value]> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child?: Value]>
) -> UnsupportedFeatureContainerMember<Root, [Child?: Value]> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child: Value]?>
) -> UnsupportedFeatureContainerMember<Root, [Child: Value]?> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value>(
    _ keyPath: KeyPath<Root, [Child?: Value]?>
) -> UnsupportedFeatureContainerMember<Root, [Child?: Value]?> { UnsupportedFeatureContainerMember() }

public func _projectionMember<Root, ID: _LegacyFeatureProjectionState & Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child]>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child]> { UnsupportedFeatureContainerMember() }

public func _projectionMember<Root, ID: _LegacyFeatureProjectionState & Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child?]>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child?]> { UnsupportedFeatureContainerMember() }

public func _projectionMember<Root, ID: _LegacyFeatureProjectionState & Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child]?>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child]?> { UnsupportedFeatureContainerMember() }

public func _projectionMember<Root, ID: _LegacyFeatureProjectionState & Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child?]?>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child?]?> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, ID: _LegacyFeatureProjectionState & Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child]>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child]> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, ID: _LegacyFeatureProjectionState & Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child?]>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child?]> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, ID: _LegacyFeatureProjectionState & Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child]?>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child]?> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, ID: _LegacyFeatureProjectionState & Hashable, Child: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [ID: Child?]?>
) -> UnsupportedFeatureContainerMember<Root, [ID: Child?]?> { UnsupportedFeatureContainerMember() }

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child?: Value]>
) -> UnsupportedFeatureContainerMember<Root, [Child?: Value]> { UnsupportedFeatureContainerMember() }

public func _projectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child?: Value]?>
) -> UnsupportedFeatureContainerMember<Root, [Child?: Value]?> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child?: Value]>
) -> UnsupportedFeatureContainerMember<Root, [Child?: Value]> { UnsupportedFeatureContainerMember() }

public func _derivedProjectionMember<Root, Child: _LegacyFeatureProjectionState & Hashable, Value: _LegacyFeatureProjectionState>(
    _ keyPath: KeyPath<Root, [Child?: Value]?>
) -> UnsupportedFeatureContainerMember<Root, [Child?: Value]?> { UnsupportedFeatureContainerMember() }
