import IdentifiedCollections

/// The identity-keyed collection diff. Three tiers:
/// - removed / inserted / reordered IDs: one structural ping on the collection's shape key;
///   departed IDs' signals and caches are pruned;
/// - same ID, `old == new`: skipped entirely — one element `==` and nothing else;
/// - same ID, changed: only that element's changed member keys fire, at
///   `(collectionKey, elementID, member)`.
@MainActor
func _diffIdentifiedCollection<Element>(
    _ old: IdentifiedArrayOf<Element>, _ new: IdentifiedArrayOf<Element>,
    registrar: FeatureStateRegistrar, key: ProjectionKey
) where Element: FeatureStateProtocol & Identifiable & Equatable {
    // Structural change (insert/remove/reorder): one ping on the collection's shape key.
    // ForEach identity re-derives; surviving rows are untouched unless they also changed;
    // coarse readers of the collection's own key wake by bubbling.
    if old.ids != new.ids {
        registrar.invalidate(key.structure)
        // Prune the signals — and cached derived outputs — of departed elements. Mandatory:
        // a stale cached output would render wrong UI if the ID returns (a stale wake was
        // merely spurious; a stale cache is incorrect).
        for id in old.ids where new[id: id] == nil {
            registrar.removeSignals(prefix: key.appending(id: id))
        }
    }

    for newElement in new {
        // Inserted elements are covered by the structural ping; their rows render fresh.
        guard let oldElement = old[id: newElement.id] else { continue }
        // The load-bearing gate: unchanged elements cost one == and nothing else.
        guard oldElement != newElement else { continue }
        Element._commit(
            old: oldElement, new: newElement,
            registrar: registrar, key: key.appending(id: newElement.id)
        )
    }
}
