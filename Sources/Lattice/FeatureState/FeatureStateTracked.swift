import IdentifiedCollections
import Observation

private protocol _FeatureStateTrackedCollection {}
extension Array: _FeatureStateTrackedCollection where Element: _FeatureStateStructure {}
extension IdentifiedArray: _FeatureStateTrackedCollection where Element: _FeatureStateStructure {}
extension Optional: _FeatureStateTrackedCollection where Wrapped: _FeatureStateTrackedCollection {}

/// Storage emitted by `@FeatureState`. Copies have independent values but share
/// their property notification channel. No callback assumes an actor or executor.
public struct _FeatureStateTracked<Value> {
    private var inline: Value?
    private var box: _FeatureStateBox<Value>?
    private let registrar = ObservationRegistrar()
    private let subject = Subject()

    private struct Subject: Observable, Sendable {
        var value: Int { 0 }
    }

    public init(_ value: Value) {
        if Value.self is any _FeatureStateStructure.Type {
            inline = nil
            box = _FeatureStateBox(value)
        } else {
            inline = .some(value)
            box = nil
        }
    }

    /// Non-observing access for generated structural descriptors and observer parameters.
    public var _untrackedValue: Value {
        get { box?.value ?? inline! }
        set {
            if box != nil {
                if isKnownUniquelyReferenced(&box) {
                    box!.value = newValue
                } else {
                    box = _FeatureStateBox(newValue)
                }
            } else {
                inline = .some(newValue)
            }
        }
        _modify {
            if box != nil {
                if !isKnownUniquelyReferenced(&box) {
                    box = _FeatureStateBox(box!.value)
                }
                yield &box!.value
            } else {
                yield &inline!
            }
        }
    }

    public var value: Value {
        get {
            registrar.access(subject, keyPath: \.value)
            return _untrackedValue
        }
        set {
            let notify = Self.shouldNotify(_untrackedValue, newValue)
            if notify { registrar.willSet(subject, keyPath: \.value) }
            _untrackedValue = newValue
            if notify { registrar.didSet(subject, keyPath: \.value) }
        }
        _modify {
            registrar.access(subject, keyPath: \.value)
            if let oldIdentity = (_untrackedValue as? any _FeatureStateStructure)?._featureStateIdentity {
                defer {
                    if oldIdentity != (_untrackedValue as? any _FeatureStateStructure)?._featureStateIdentity {
                        registrar.withMutation(of: subject, keyPath: \.value) {}
                    }
                }
                yield &_untrackedValue
            } else {
                registrar.willSet(subject, keyPath: \.value)
                defer { registrar.didSet(subject, keyPath: \.value) }
                yield &_untrackedValue
            }
        }
    }

    private static func shouldNotify(_ old: Value, _ new: Value) -> Bool {
        if let old = old as? any _FeatureStateStructure,
            let new = new as? any _FeatureStateStructure {
            return old._featureStateIdentity != new._featureStateIdentity
        }
        // Tracked collections keep native COW. Whole-value equality would compare
        // row contents; replacement conservatively invalidates the field instead.
        // Result records reconcile selected rows using IDs and tracked locations.
        if Value.self is any _FeatureStateTrackedCollection.Type { return true }
        if let old = old as? any Equatable {
            func differs<T: Equatable>(_ old: T) -> Bool { (new as? T).map { old != $0 } ?? true }
            return differs(old)
        }
        if Value.self is AnyObject.Type {
            return old as AnyObject !== new as AnyObject
        }
        return true
    }

    // Internal evidence for the COW contract; storage identity is not observation identity.
    var storageIdentity: ObjectIdentifier? { box.map(ObjectIdentifier.init) }
}

// A box is mutated only after an ARC uniqueness check. Shared boxes are never
// written, and uniqueness is established before yielding mutable storage.
// Concurrent use is allowed on separate wrapper values, never one variable.
private final class _FeatureStateBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension _FeatureStateBox: @unchecked Sendable where Value: Sendable {}
extension _FeatureStateTracked: Sendable where Value: Sendable {}
extension _FeatureStateTracked: Equatable where Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs._untrackedValue == rhs._untrackedValue }
}
extension _FeatureStateTracked: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) { _untrackedValue.hash(into: &hasher) }
}
extension _FeatureStateTracked: Decodable where Value: Decodable {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Value.self))
    }
}
extension _FeatureStateTracked: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(_untrackedValue)
    }
}
