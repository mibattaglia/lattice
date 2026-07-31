import Observation

/// The per-ViewModel side table: one signal object per accessed key, plus the derivation
/// cache. A view body that reads a projected member touches that key's signal, which
/// registers with the Observation framework as usual. Commit collects the keys whose value
/// or output changed and pokes each signal exactly once at the end of the batch —
/// invalidating exactly the views that read those members. Nothing about the state value
/// itself is observable.
@MainActor
public final class FeatureStateRegistrar {

    /// One signal per accessed projection key. A manual `Observable` conformance over a raw
    /// `ObservationRegistrar`: observation is keyed on (object identity, key path), and the
    /// single anchor key path is the stored `cachedOutput` slot. For derived-member keys the
    /// anchor doubles as the derivation cache; for stored-member, shape, subtree, and root
    /// keys it stays `nil` — the committed state itself is their storage.
    final class Signal: Observable {
        private let registrar = ObservationRegistrar()

        /// Populated for derived members (the member's last committed output); nil for
        /// everything else.
        fileprivate var cachedOutput: Any?

        /// Read side: register observation access on the anchor slot.
        func access() { registrar.access(self, keyPath: \Signal.cachedOutput) }

        /// Notify without storing: the mutation already happened elsewhere (in the
        /// committed state value); this delivers the notification for it.
        fileprivate func fire() {
            registrar.withMutation(of: self, keyPath: \Signal.cachedOutput) {}
        }

        /// Notify and store a derived member's freshly computed output in one mutation.
        fileprivate func fire(storing newOutput: Any) {
            registrar.withMutation(of: self, keyPath: \Signal.cachedOutput) {
                cachedOutput = newOutput
            }
        }
    }

    private var signals: [ProjectionKey: Signal] = [:]

    /// Non-nil while a `commit(_:)` batch is open: the keys to poke at batch close, plus
    /// the fresh outputs to store into derived signals when their poke is delivered.
    private var batch: (fired: Set<ProjectionKey>, outputs: [ProjectionKey: Any])?

    /// Internal test seam: invoked once for every signal poke actually delivered (batched
    /// pokes at batch close, immediate fires otherwise). `RecordingRegistrar`-style test
    /// helpers install a closure here to record fires per commit.
    var onPoke: ((ProjectionKey) -> Void)?

    public init() {}

    // MARK: Read side

    /// Register observation access on `key`. Stored-member leaves, shape keys, and
    /// explicitly coarse reads (subtree keys, the root whole-state key) come through here;
    /// the value itself is read straight from committed state by the caller.
    func access(_ key: ProjectionKey) {
        signal(for: key).access()
    }

    /// Read side for derived members: serve the cached output, seeding it on the first
    /// read. Registers access either way. Seeding stores without notifying — nothing
    /// changed; the output was merely never cached.
    func derived<Output>(_ key: ProjectionKey, compute: () -> Output) -> Output {
        let signal = signal(for: key)
        signal.access()
        if let cached = signal.cachedOutput {
            // The generator emits the key and the compute closure for the same member;
            // the cast cannot fail (same argument as the `_viewKeyPaths` casts).
            return cached as! Output
        }
        let fresh = compute()
        signal.cachedOutput = fresh
        return fresh
    }

    // MARK: Commit side

    /// Batch wrapper the host installs around the commit diff. Keys fired inside the body
    /// collect into a set; at close, the set expands with every ancestor prefix that has a
    /// signal (bubbling), and each collected signal is poked exactly once — with its fresh
    /// derived output where one was computed, empty otherwise. The root signal, when one is
    /// registered, is therefore poked exactly when something visible changed; a domain-only
    /// commit pokes nobody.
    func commit(_ body: () -> Void) {
        batch = (fired: [], outputs: [:])
        body()
        let (fired, outputs) = batch!
        batch = nil
        var toPoke: Set<ProjectionKey> = []
        for key in fired {
            toPoke.insert(key)
            var prefix = key
            while !prefix.components.isEmpty {  // O(depth) walk per fired key
                prefix.components.removeLast()
                if signals[prefix] != nil { toPoke.insert(prefix) }
            }
        }
        for key in toPoke {
            guard let signal = signals[key] else { continue }
            if let output = outputs[key] {
                signal.fire(storing: output)
            } else {
                signal.fire()
            }
            onPoke?(key)
        }
    }

    /// Fire one key: a stored member's value changed. Inside a batch, recorded
    /// unconditionally so that registered ancestors bubble even when the leaf itself has
    /// never been read; outside one (tests, direct use), delivered immediately to the
    /// key's own signal when one exists.
    func invalidate(_ key: ProjectionKey) {
        if batch != nil {
            batch!.fired.insert(key)
        } else if let signal = signals[key] {
            signal.fire()
            onPoke?(key)
        }
    }

    /// Coarse fire: everything at or under `prefix` changed at once (enum case flips,
    /// optional-presence flips). Fires every registered signal under the prefix — the
    /// prefix's own key included — and clears every cached output under it: an output
    /// cached against the departed shape must never be served against the new one. The
    /// next commit (or first read) reseeds and fires conservatively. Inside a batch the
    /// prefix itself is also recorded unconditionally, so registered ancestors bubble even
    /// when nothing under the prefix has been read.
    /// ponytail: O(#accessed keys) scan; index by first component if profiling demands.
    public func invalidate(prefix: ProjectionKey) {
        if batch != nil { batch!.fired.insert(prefix) }
        for (key, signal) in signals where key.hasPrefix(prefix) {
            signal.cachedOutput = nil
            if batch != nil {
                batch!.fired.insert(key)
            } else {
                signal.fire()
                onPoke?(key)
            }
        }
    }

    /// Commit side for derived members; the generated `_commit` emits one call per
    /// computed member. Three cases:
    /// - no signal for `key` (the member has never been read): `compute` does not run —
    ///   an unobserved derived member costs nothing at commit and contributes nothing to
    ///   coarse fires;
    /// - cached output present: compute once, compare by `==`; on change, fire and store;
    /// - signal present but cache empty (first commit after a coarse drop): compute,
    ///   store, and fire conservatively.
    public func commitDerived<Output: Equatable>(_ key: ProjectionKey, _ compute: () -> Output) {
        guard let signal = signals[key] else { return }
        let fresh = compute()
        if let cached = signal.cachedOutput, (cached as! Output) == fresh { return }
        if batch != nil {
            batch!.fired.insert(key)
            batch!.outputs[key] = fresh
        } else {
            signal.fire(storing: fresh)
            onPoke?(key)
        }
    }

    /// Structural pruning: drop every signal — and its cached output — at or under
    /// `prefix`. The collection diff calls this for removed element IDs; a surviving
    /// signal holding a stale cached output would serve wrong UI if the ID returned.
    func removeSignals(prefix: ProjectionKey) {
        for key in signals.keys where key.hasPrefix(prefix) {
            signals.removeValue(forKey: key)
        }
    }

    private func signal(for key: ProjectionKey) -> Signal {
        if let existing = signals[key] { return existing }
        let created = Signal()
        signals[key] = created
        return created
    }
}
