import Observation

/// A membership/order snapshot containing stable, read-only filtered row handles.
/// Held elements follow selected commits, retain on omission, and reconnect by ID.
public struct ScopedViewModelCollection<Row: FeatureStateProtocol & Identifiable>: RandomAccessCollection {
    public typealias Element = ScopedRowViewModel<Row>
    public typealias Index = Int
    private let elements: [Element]
    // Keep an empty materialized result enrolled even without any row handles.
    private let record: AnyObject
    private let context: AnyObject
    private let owner: AnyObject

    @MainActor
    init(elements: [Element], record: AnyObject, context: AnyObject, owner: AnyObject) {
        self.elements = elements
        self.record = record
        self.context = context
        self.owner = owner
    }

    public var startIndex: Int { elements.startIndex }
    public var endIndex: Int { elements.endIndex }
    public subscript(index: Int) -> Element { elements[index] }
}

@MainActor
final class _FeatureStateSignal: Observable {
    private let registrar = ObservationRegistrar()
    private var revision: Int { 0 }
    func access() { registrar.access(self, keyPath: \.revision) }
    func notify() { registrar.withMutation(of: self, keyPath: \.revision) {} }
}

@MainActor
private final class _WeakFeatureStateReference {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}

@MainActor
protocol _FeatureStateRegistration: AnyObject {
    func stage() -> [_FeatureStateSignal]
}

/// Flat, weak, creation-ordered worklist: parents register before descendants.
/// It is called only at the existing sent/emitted ViewModel commit boundary.
@MainActor
final class _FeatureStateRegistry {
    private var entries: [_WeakFeatureStateReference] = []

    func insert(_ entry: any _FeatureStateRegistration) {
        entries.removeAll { $0.value == nil }
        entries.append(_WeakFeatureStateReference(entry))
    }

    func stage() -> [_FeatureStateSignal] {
        entries.removeAll { $0.value == nil }
        let work = entries.compactMap { $0.value as? any _FeatureStateRegistration }
        return work.flatMap { $0.stage() }
    }

    var count: Int { entries.filter { $0.value != nil }.count }
}

/// Root contexts read the owner's committed value. Other contexts read a retained
/// slot. Contexts never own the ViewModel; public handles do, through ARC.
@MainActor
final class _FeatureStateContext<State> {
    let registry: _FeatureStateRegistry
    let signal: _FeatureStateSignal
    let value: () -> State
    let isLive: () -> Bool
    private var children: [AnyKeyPath: _WeakFeatureStateReference] = [:]
    // At most one record per materialized descriptor in this context. A nested
    // context's records die with it; root records are bounded by root metadata.
    private var results: [AnyKeyPath: AnyObject] = [:]

    init(
        registry: _FeatureStateRegistry, signal: _FeatureStateSignal,
        value: @escaping () -> State, isLive: @escaping () -> Bool
    ) {
        self.registry = registry
        self.signal = signal
        self.value = value
        self.isLive = isLive
    }

    func read() -> State {
        signal.access()
        return value()
    }

    func child<Child: FeatureStateProtocol>(
        key: AnyKeyPath, seed: Child, read: @escaping (State) -> Child?
    ) -> _FeatureStateContext<Child> {
        children = children.filter { $0.value.value != nil }
        if let existing = children[key]?.value as? _FeatureStateContext<Child> { return existing }
        let slot = _FeatureStateSlot(seed, isLive: isLive(), resolve: { [self] in
            isLive() ? read(value()) : nil
        })
        let context = _FeatureStateContext<Child>(
            registry: registry, signal: slot.signal,
            value: { slot.value }, isLive: { slot.isLive }
        )
        children[key] = _WeakFeatureStateReference(context)
        registry.insert(slot)
        return context
    }

    func rows<Row: FeatureStateProtocol & Identifiable>(
        key: AnyKeyPath, values: [Row], read: @escaping (State) -> [Row], owner: AnyObject
    ) -> ScopedViewModelCollection<Row> {
        let record: _FeatureStateResult<State, Row>
        if let existing = results[key] as? _FeatureStateResult<State, Row> {
            record = existing
        } else {
            record = _FeatureStateResult(parent: self, read: read)
            results[key] = record
            registry.insert(record)
        }
        return record.collection(values: values, owner: owner)
    }
}

@MainActor
private final class _FeatureStateSlot<State: FeatureStateProtocol>: _FeatureStateRegistration {
    var value: State
    var isLive: Bool
    let signal = _FeatureStateSignal()
    private let resolve: () -> State?

    init(_ value: State, isLive: Bool, resolve: @escaping () -> State?) {
        self.value = value
        self.isLive = isLive
        self.resolve = resolve
    }

    func stage() -> [_FeatureStateSignal] { install(resolve()) }

    func install(_ current: State?) -> [_FeatureStateSignal] {
        guard let current else {
            isLive = false
            return []
        }
        let changed = !isLive || value._featureStateIdentity != current._featureStateIdentity
        // Assignment is mandatory even at the same location and with no reread.
        value = current
        isLive = true
        return changed ? [signal] : []
    }
}

@MainActor
private final class _FeatureStateResult<Parent, Row: FeatureStateProtocol & Identifiable>: _FeatureStateRegistration {
    // The parent owns its materialized records; the record must not own it back.
    private unowned let parent: _FeatureStateContext<Parent>
    private let read: (Parent) -> [Row]
    private var handles: [Row.ID: _WeakFeatureStateReference] = [:]
    private var contexts: [Row.ID: _WeakFeatureStateReference] = [:]
    private var slots: [Row.ID: _WeakFeatureStateReference] = [:]

    init(parent: _FeatureStateContext<Parent>, read: @escaping (Parent) -> [Row]) {
        self.parent = parent
        self.read = read
    }

    private func index(_ values: [Row]) -> [Row.ID: Row] {
        var index: [Row.ID: Row] = [:]
        for value in values {
            precondition(index.updateValue(value, forKey: value.id) == nil, "FeatureState result contains duplicate row IDs")
        }
        return index
    }

    func collection(values: [Row], owner: AnyObject) -> ScopedViewModelCollection<Row> {
        _ = index(values)
        prune()
        let elements = values.map { row -> ScopedRowViewModel<Row> in
            if let handle = handles[row.id]?.value as? ScopedViewModel<Row, Never> {
                return ScopedRowViewModel(id: row.id, model: handle)
            }
            let context: _FeatureStateContext<Row>
            if let existing = contexts[row.id]?.value as? _FeatureStateContext<Row> {
                context = existing
            } else {
                let slot = _FeatureStateSlot(row, isLive: parent.isLive(), resolve: { nil })
                context = _FeatureStateContext<Row>(
                    registry: parent.registry, signal: slot.signal,
                    // Retain the logical parent context, not just an unowned record.
                    value: { [parent] in _ = parent; return slot.value },
                    isLive: { slot.isLive }
                )
                contexts[row.id] = _WeakFeatureStateReference(context)
                slots[row.id] = _WeakFeatureStateReference(slot)
            }
            let handle = ScopedViewModel<Row, Never>(context: context, owner: owner, send: _uninhabitedFeatureAction)
            handles[row.id] = _WeakFeatureStateReference(handle)
            return ScopedRowViewModel(id: row.id, model: handle)
        }
        return ScopedViewModelCollection(elements: elements, record: self, context: parent, owner: owner)
    }

    func stage() -> [_FeatureStateSignal] {
        prune()
        let selected = parent.isLive() ? index(read(parent.value())) : [:]
        return slots.flatMap { id, entry in
            (entry.value as? _FeatureStateSlot<Row>)?.install(selected[id]) ?? []
        }
    }

    private func prune() {
        handles = handles.filter { $0.value.value != nil }
        contexts = contexts.filter { $0.value.value != nil }
        slots = slots.filter { $0.value.value != nil }
    }
}

/// An identified, read-only row handle. The ID is a value; reads and nested scopes
/// remain MainActor-owned. Actions are wired by the consumer, never by the result.
@dynamicMemberLookup
public struct ScopedRowViewModel<Row: FeatureStateProtocol & Identifiable>: Identifiable {
    public let id: Row.ID
    private let model: ScopedViewModel<Row, Never>

    @MainActor
    init(id: Row.ID, model: ScopedViewModel<Row, Never>) {
        self.id = id
        self.model = model
    }

    @MainActor
    public subscript<Value>(
        dynamicMember member: KeyPath<Row._ViewMembers, FeatureStateValueMember<Row, Value>>
    ) -> Value { model[dynamicMember: member] }

    @MainActor
    public subscript<Child: FeatureStateProtocol & Identifiable>(
        dynamicMember member: KeyPath<Row._ViewMembers, FeatureStateRowsMember<Row, Child>>
    ) -> ScopedViewModelCollection<Child> { model[dynamicMember: member] }

    @MainActor
    public func scope<Child: FeatureStateProtocol>(
        state member: KeyPath<Row._ViewMembers, FeatureStateChildMember<Row, Child>>
    ) -> ScopedViewModel<Child, Never> { model.scope(state: member) }

    @MainActor
    public func scopeIfPresent<Child: FeatureStateProtocol>(
        state member: KeyPath<Row._ViewMembers, FeatureStateOptionalMember<Row, Child>>
    ) -> ScopedViewModel<Child, Never>? { model.scopeIfPresent(state: member) }

    // Lets tests prove reference reuse without exposing raw Row or model access.
    @MainActor var handleIdentity: ObjectIdentifier { ObjectIdentifier(model) }
}

extension ScopedRowViewModel: Sendable where Row.ID: Sendable {}
