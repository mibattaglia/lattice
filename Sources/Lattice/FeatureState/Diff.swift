import IdentifiedCollections

// The overload-ranked member diff. The macro emits one `Lattice._diff(...)` call per
// visible **stored** member. Which diff runs is decided by generic overload ranking, so the
// macro never needs to know member types semantically. Computed members do not flow through
// `_diff` at all: the macro classifies stored vs computed syntactically and emits
// `registrar.commitDerived(...)` for computed members instead.
//
// Ranking summary (most to least specific): identified collection → optional child →
// child + `Equatable` → child → leaf `Equatable` (disfavored) → unavailable catch-all.

// Nested feature state that is also Equatable: cheap whole-value gate, then recurse.
@MainActor
public func _diff<Child: FeatureStateProtocol & Equatable>(
    _ old: Child, _ new: Child,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    guard old != new else { return }
    Child._commit(old: old, new: new, registrar: registrar, key: key)
}

// Nested feature state: delegate to the child's generated commit.
@MainActor
public func _diff<Child: FeatureStateProtocol>(
    _ old: Child, _ new: Child,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    Child._commit(old: old, new: new, registrar: registrar, key: key)
}

// Optional feature state (optional stored members; enum case accessors).
@MainActor
public func _diff<Child: FeatureStateProtocol>(
    _ old: Child?, _ new: Child?,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    switch (old, new) {
    case (nil, nil):
        break
    case (let old?, let new?):
        Child._commit(old: old, new: new, registrar: registrar, key: key)
    default:
        // Presence flipped: everything under this slot changed at once. The prefix fire
        // covers the slot's own key, the shape key, and every registered descendant, and
        // clears the derived caches under the slot.
        registrar.invalidate(prefix: key)
    }
}

// Identified collections of feature states: identity-keyed diff (see CollectionDiff.swift).
@MainActor
public func _diff<Element>(
    _ old: IdentifiedArrayOf<Element>, _ new: IdentifiedArrayOf<Element>,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) where Element: FeatureStateProtocol & Identifiable & Equatable {
    _diffIdentifiedCollection(old, new, registrar: registrar, key: key)
}

// Leaf values: fire when the stored value changed.
// Disfavored so that any of the structure-aware overloads above outranks it when both apply.
@MainActor
@_disfavoredOverload
public func _diff<Value: Equatable>(
    _ old: Value, _ new: Value,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) {
    guard old != new else { return }
    registrar.invalidate(key)
}

// Unsupported: a view-visible member that is not Equatable. Unavailable declarations lose
// overload resolution to available ones, so this only matches when nothing else can — and
// then fails compilation with an actionable message at the expansion site.
@available(
    *, unavailable,
    message: """
        view-visible members must be Equatable — make the type Equatable, \
        mark the member '@Domain', or make it 'private'
        """
)
@MainActor
public func _diff<Value>(
    _ old: Value, _ new: Value,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) { fatalError() }
