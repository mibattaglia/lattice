import Foundation

/// Structural observation identity, separate from a state's user-defined equality.
public indirect enum _FeatureStateIdentity: Hashable, Sendable {
    case location(UUID)
    case absent
    case present(_FeatureStateIdentity)
    case `case`(Int, _FeatureStateIdentity?)
    case scalar(_FeatureStateScalarIdentity)
}

/// Macro/runtime scalar classification, not aggregate tracking or an advertised
/// customization point. Containers and optional payloads are not in this category.
public protocol _FeatureStateScalarPayload: Hashable, Sendable {}

extension Bool: _FeatureStateScalarPayload {}
extension String: _FeatureStateScalarPayload {}
extension Character: _FeatureStateScalarPayload {}
extension Int: _FeatureStateScalarPayload {}
extension Int8: _FeatureStateScalarPayload {}
extension Int16: _FeatureStateScalarPayload {}
extension Int32: _FeatureStateScalarPayload {}
extension Int64: _FeatureStateScalarPayload {}
extension UInt: _FeatureStateScalarPayload {}
extension UInt8: _FeatureStateScalarPayload {}
extension UInt16: _FeatureStateScalarPayload {}
extension UInt32: _FeatureStateScalarPayload {}
extension UInt64: _FeatureStateScalarPayload {}
extension Float: _FeatureStateScalarPayload {}
extension Double: _FeatureStateScalarPayload {}

/// An immutable, typed value snapshot. Exact equality, not a scalar hash or
/// AnyHashable's numeric bridging, determines an enum replacement boundary.
public struct _FeatureStateScalarIdentity: Hashable, Sendable {
    private let value: any Hashable & Sendable

    init<Value: Hashable & Sendable>(_ value: Value) { self.value = value }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard ObjectIdentifier(type(of: lhs.value)) == ObjectIdentifier(type(of: rhs.value)) else { return false }
        func equals<Value: Hashable & Sendable>(_ value: Value) -> Bool {
            (rhs.value as? Value).map { value == $0 } ?? false
        }
        return equals(lhs.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(type(of: value)))
        value.hash(into: &hasher)
    }
}

/// The generated location participates in neither value equality nor coding.
public struct _FeatureStateLocation: Sendable, Equatable, Hashable, Codable {
    public let identity: _FeatureStateIdentity

    public init() { identity = .location(UUID()) }
    public static func == (_: Self, _: Self) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}
    public init(from decoder: any Decoder) throws { self.init() }
    public func encode(to encoder: any Encoder) throws {}
}

/// Used by storage to recognize tracked aggregates semantically, including generics
/// and optional wrappers. It is not inferred from a property's type spelling.
public protocol _FeatureStateStructure {
    var _featureStateIdentity: _FeatureStateIdentity { get }
}

extension Optional: _FeatureStateStructure where Wrapped: _FeatureStateStructure {
    public var _featureStateIdentity: _FeatureStateIdentity {
        switch self {
        case .none: .absent
        case .some(let value): .present(value._featureStateIdentity)
        }
    }
}

public func _featureStateCaseIdentity<State: FeatureStateProtocol>(
    _ tag: Int, _ value: State
) -> _FeatureStateIdentity {
    .case(tag, value._featureStateIdentity)
}

@_disfavoredOverload
public func _featureStateCaseIdentity<Value: _FeatureStateScalarPayload>(
    _ tag: Int, _ value: Value
) -> _FeatureStateIdentity {
    .case(tag, .scalar(_FeatureStateScalarIdentity(value)))
}

@available(*, unavailable, message: "annotated feature enum cases require one tracked payload or supported scalar; use one tracked payload struct for other cases")
public func _featureStateCaseIdentity<Value>(_ tag: Int, _ value: Value) -> _FeatureStateIdentity {
    fatalError()
}
