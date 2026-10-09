import Foundation

/// Structural observation identity, separate from a state's user-defined equality.
public indirect enum _FeatureStateIdentity: Hashable, Sendable {
    case location(UUID)
    case absent
    case present(_FeatureStateIdentity)
    case `case`(Int, _FeatureStateIdentity?)
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

@available(*, unavailable, message: "annotated feature enum cases require one tracked payload struct; leave ordinary payload enums unannotated")
public func _featureStateCaseIdentity<Value>(_ tag: Int, _ value: Value) -> _FeatureStateIdentity {
    fatalError()
}
