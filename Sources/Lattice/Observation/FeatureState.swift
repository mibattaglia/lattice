import Foundation
import Observation

#if canImport(IdentifiedCollections)
    import IdentifiedCollections
#endif

/// A value type whose observation is tracked per member and whose view-facing surface is
/// `ViewState`. Apply the `@FeatureState` macro; never conform manually.
public protocol FeatureState: Observable {
    /// The macro-generated projection views read through. Omits `@Domain` members.
    associatedtype ViewState: ViewStateProjection where ViewState.State == Self
    var _$id: ObservableStateID { get }
    mutating func _$willModify()
}

/// A unique identifier for a observed value.
public struct ObservableStateID: Equatable, Hashable, Sendable {
    @usableFromInline
    var location: UUID {
        get { self.storage.id.location }
        set {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = Storage(id: self.storage.id)
            }
            self.storage.id.location = newValue
        }
    }

    private var storage: Storage

    #if DEBUG
        /// Test-only: the identity of the backing storage, so tests can assert that an id's
        /// storage instance is shared across content-equal assignments.
        public var _$storageObjectID: ObjectIdentifier { ObjectIdentifier(self.storage) }
    #endif

    private init(storage: Storage) {
        self.storage = storage
    }

    public init() {
        self.init(storage: Storage(id: .location(UUID())))
    }

    /// A shared identity for values that carry no observable content of their own, such as
    /// payloadless enum cases. Tagging `_$inert` with a case index yields an id that is stable
    /// across accesses and distinct across cases.
    public static let _$inert = Self()

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.id == rhs.storage.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.storage.id)
    }

    @inlinable
    public static func _$id<T>(for value: T) -> Self {
        (value as? any FeatureState)?._$id ?? Self()
    }

    @inlinable
    public static func _$id(for value: some FeatureState) -> Self {
        value._$id
    }

    public func _$tag(_ tag: Int) -> Self {
        Self(storage: Storage(id: .tag(tag, self.storage.id)))
    }

    @inlinable
    public mutating func _$willModify() {
        self.location = UUID()
    }

    private final class Storage: @unchecked Sendable {
        fileprivate var id: ID

        init(id: ID = .location(UUID())) {
            self.id = id
        }

        enum ID: Equatable, Hashable, Sendable {
            case location(UUID)
            indirect case tag(Int, ID)

            var location: UUID {
                get {
                    switch self {
                    case .location(let location):
                        return location
                    case .tag(_, let id):
                        return id.location
                    }
                }
                set {
                    switch self {
                    case .location:
                        self = .location(newValue)
                    case .tag(let tag, var id):
                        id.location = newValue
                        self = .tag(tag, id)
                    }
                }
            }
        }
    }
}

@inlinable
public func _$isIdentityEqual<T: FeatureState>(
    _ lhs: T, _ rhs: T
) -> Bool {
    lhs._$id == rhs._$id
}

@inlinable
public func _$isIdentityEqual<C: Collection>(
    _ lhs: C,
    _ rhs: C
) -> Bool
where C.Element: FeatureState {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0._$id == $1._$id }
}

// NB: This is a fast path so that String is not checked as a collection.
@inlinable
public func _$isIdentityEqual(_ lhs: String, _ rhs: String) -> Bool {
    false
}

@inlinable
public func _$isIdentityEqual<T>(_ lhs: T, _ rhs: T) -> Bool {
    guard !_isPOD(T.self) else { return false }

    func openCollection<C: Collection>(_ lhs: C, _ rhs: Any) -> Bool {
        guard C.Element.self is any FeatureState.Type else {
            return false
        }

        #if canImport(IdentifiedCollections)
            func openIdentifiable<Element: Identifiable>(_: Element.Type) -> Bool? {
                guard
                    let lhs = lhs as? IdentifiedArrayOf<Element>,
                    let rhs = rhs as? IdentifiedArrayOf<Element>
                else {
                    return nil
                }
                return areOrderedSetsDuplicates(lhs.ids, rhs.ids)
            }

            if let identifiable = C.Element.self as? any Identifiable.Type,
                let result = openIdentifiable(identifiable)
            {
                return result
            }
        #endif

        if let rhs = rhs as? C {
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(_$isIdentityEqual)
        } else {
            return false
        }
    }

    if let lhs = lhs as? any FeatureState, let rhs = rhs as? any FeatureState {
        return lhs._$id == rhs._$id
    } else if let lhs = lhs as? any Collection {
        return openCollection(lhs, rhs)
    } else {
        return false
    }
}

@inlinable
public func _$willModify<T>(_: inout T) {}
@inlinable
public func _$willModify<T: FeatureState>(_ value: inout T) {
    value._$willModify()
}
