import Observation

/// Host-owned observation signals and ever-accessed derived outputs.
/// State values contain neither observation storage nor copy identity.
@MainActor
public final class FeatureStateRegistrar {
    private final class Signal: Observable {
        private let observation = ObservationRegistrar()
        private var anchor: Bool = false
        func access() { observation.access(self, keyPath: \Signal.anchor) }
        func fire() { observation.withMutation(of: self, keyPath: \Signal.anchor) {} }
    }

    private struct Cached<Output> { let value: Output }
    private var signals: [ProjectionKey: Signal] = [:]
    private var outputs: [ProjectionKey: Any] = [:]
    private var pending: Set<ProjectionKey> = []
    private var isCommitting = false

    init() {}

    func access(_ key: ProjectionKey) {
        if signals[key] == nil { signals[key] = Signal() }
        signals[key]?.access()
    }

    func derived<Output>(_ key: ProjectionKey, compute: () -> Output) -> Output {
        access(key)
        if let cached = outputs[key] {
            guard let typed = cached as? Cached<Output> else {
                preconditionFailure("Projection cache type mismatch")
            }
            return typed.value
        }
        let value = compute()
        outputs[key] = Cached(value: value)
        return value
    }

    // The host publishes its new stored snapshot before opening this batch.
    // All output publication/pruning precedes any synchronous willSet callback.
    func commit(_ body: () -> Void) {
        precondition(!isCommitting, "Direct FeatureStateRegistrar commit reentrancy is unsupported")
        isCommitting = true
        body()
        var keys = pending
        for key in pending {
            var prefix = key
            while !prefix.components.isEmpty {
                prefix.components.removeLast()
                if signals[prefix] != nil { keys.insert(prefix) }
            }
        }
        let notifications = keys.compactMap { signals[$0] }
        for prefix in prunedPrefixes {
            for key in Array(signals.keys) where key.hasPrefix(prefix) { signals.removeValue(forKey: key) }
        }
        prunedPrefixes.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        for signal in notifications { signal.fire() }
        isCommitting = false
    }

    func invalidate(_ key: ProjectionKey) {
        precondition(isCommitting, "Projection invalidation requires a host commit")
        pending.insert(key)
    }

    func invalidate(prefix: ProjectionKey) {
        invalidate(prefix)
        for key in signals.keys where key.hasPrefix(prefix) { pending.insert(key) }
        for key in Array(outputs.keys) where key.hasPrefix(prefix) { outputs.removeValue(forKey: key) }
    }

    func commitDerived<Output>(
        _ key: ProjectionKey, coarse: Bool,
        areEqual: (Output, Output) -> Bool, compute: () -> Output
    ) -> (old: Output?, new: Output)? {
        guard signals[key] != nil else { return nil }
        let fresh = compute()
        var previous: Output?
        if let cached = outputs[key] {
            guard let typed = cached as? Cached<Output> else {
                preconditionFailure("Projection cache type mismatch")
            }
            previous = typed.value
            if areEqual(typed.value, fresh) { return nil }
        }
        if coarse { invalidate(prefix: key) } else { invalidate(key) }
        outputs[key] = Cached(value: fresh)
        return (previous, fresh)
    }

    func removeSignals(prefix: ProjectionKey) {
        // Capture removed signals for this commit's notifications before pruning.
        invalidate(prefix: prefix)
        // Caches drop now; signal storage drops after capturing notification targets.
        prunedPrefixes.append(prefix)
    }

    private var prunedPrefixes: [ProjectionKey] = []
}
