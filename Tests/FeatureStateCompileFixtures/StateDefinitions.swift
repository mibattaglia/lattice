import Lattice
import CasePaths
import IdentifiedCollections
import os

@FeatureState
public struct FixtureChild: Equatable, Sendable {
    public var title: String = "Visible"
    public var sibling: Int = 0
    @Domain public var secret: Int = 7
    private var privateValue: Int = 0
    fileprivate var fileValue: Int = 0
    public var label: String { "\(title):\(secret + privateValue + fileValue)" }
    public init() {}
}

@FeatureState
public struct FixtureParent: Equatable, Sendable {
    public var child: FixtureChild = FixtureChild()
    public init() {}
}

@FeatureState
public struct FixtureRoot<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value
    public var child: FixtureChild = FixtureChild()
    public var optional: FixtureParent? = FixtureParent()
    public var phase: FixturePhase = .ready(FixtureChild())
    @Domain public var rows: [FixtureRow] = []
    @Domain public var hiddenCount: Int = 0
    public var query: String = ""
    public var label: String { "\(hiddenCount) items" }
    public var filteredRows: [FixtureRow] {
        rows.filter { $0.eligible && (query.isEmpty || $0.title.contains(query)) }
            .sorted { $0.title < $1.title }
    }
    public var identifiedRows: IdentifiedArrayOf<FixtureRow> { IdentifiedArray(uniqueElements: filteredRows) }
    var moduleOnly: String = "Internal"
    package var packageOnly: String = "Package"
    public private(set) var readOnly: Int = 42
    public init(value: Value) { self.value = value }
}

@FeatureState
public enum FixturePhase: Equatable, Sendable {
    case idle
    case ready(FixtureChild)
    case alternate(FixtureChild)
    case count(Int)
    case otherCount(Int)
    case text(String)
    case flag(Bool)
    case character(Character)
    case int8(Int8)
    case int16(Int16)
    case int32(Int32)
    case int64(Int64)
    case unsigned(UInt)
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case uint64(UInt64)
    case float(Float)
    case double(Double)

    @Domain public var domainSummary: String { "Hand-authored domain member" }
}

// No Equatable or Sendable request is needed just to annotate this declaration.
@FeatureState
public enum FixtureScalarDeclaration {
    case count(Int)
}

@FeatureState
public struct FixtureScalarContexts: Equatable, Sendable {
    public var nested: FixturePhase = .count(1)
    public var optional: FixturePhase? = .count(1)
    public init() {}
}

@CasePathable
@FeatureState
public enum FixtureCasePathPhase: Equatable, Sendable {
    case idle
    case ready(FixtureChild)
}

@FeatureState
public struct FixtureRow: Equatable, Identifiable, Sendable {
    public let id: Int
    public var title: String
    public var sibling: Int = 0
    public var child: FixtureChild = FixtureChild()
    @Domain public var eligible: Bool = true
    private var privateValue: Int = 0
    fileprivate var fileValue: Int = 0
    var moduleOnly: Int = 0
    package var packageOnly: Int = 0
    public init(id: Int, title: String) { self.id = id; self.title = title }
}

@CasePathable
public enum FixtureAction: Sendable {
    case query(String)
    case child(FixtureChildAction)
    case row(Int, FixtureChildAction)
}

@CasePathable
public enum FixtureChildAction: Sendable {
    case title(String)
}

public struct FixtureInteractor: Interactor, Sendable {
    public init() {}
    public var body: some Interactor<FixtureRoot<Int>, FixtureAction> {
        Interact { state, action in
            switch action {
            case .query(let query): state.query = query
            case .child(.title(let title)): state.child.title = title
            case .row(let id, .title(let title)):
                if let index = state.rows.firstIndex(where: { $0.id == id }) { state.rows[index].title = title }
            }
            return .none
        }
    }
}

public typealias FixtureModel = ViewModel<Feature<FixtureAction, FixtureRoot<Int>, _FeatureStatePresentation>>

@MainActor
public func makeFixtureModel() -> FixtureModel {
    ViewModel(initialDomainState: FixtureRoot(value: 1), feature: Feature(interactor: FixtureInteractor()))
}

public struct FixtureOuter<Value: Equatable & Sendable>: Sendable {
    @FeatureState
    public struct Inner: Sendable {
        public var value: Value
        public var `default`: Int = 0
        @Domain public var raw: String = ""
        public var label: String { raw }
    }
}

@available(macOS 14, iOS 17, watchOS 10, *)
@FeatureState
public struct AvailableFixture: Sendable {
    public var value: Int = 0
}

@FeatureState
public struct SelfFixture: Equatable, Sendable {
    public var value: Int = 0
    @Domain public var hidden: Int = 0
    @Domain public var copy: Self { self }
}

@FeatureState
public struct ExplicitFixture: FeatureStateProtocol, Sendable {
    public var value: Int = 0
}

@FeatureState
public struct GenericRow<Value: Equatable & Sendable>: Identifiable, Equatable, Sendable {
    public let id: Int
    public var value: Value
}

@FeatureState
public struct GenericStructures<Value: Equatable & Sendable>: Sendable {
    public typealias Rows = [GenericRow<Value>]
    public var child: GenericRow<Value>
    public var optional: GenericRow<Value>?
    public var rows: IdentifiedArrayOf<GenericRow<Value>>
    public var computedRows: Rows { rows.filter { $0.id > 0 }.sorted { $0.id < $1.id } }
}

@FeatureState
public struct OpaqueLeafRoot: Sendable {
    public struct Leaf: Sendable { public var wholeValue: Int }
    public var value: Leaf
    public var primitives: [Int] = []
    public var optionalValue: Int? = nil
    public var observed: Int = 0 { willSet {} didSet {} }
}

@FeatureState
public struct FixtureObservedValue: Sendable {
    @Domain public var oldValues: [Int] = []
    @Domain public var reenterWillSet: Bool = false
    public var value: Int = 0 {
        willSet(incoming) {
            if reenterWillSet && incoming == 2 {
                reenterWillSet = false
                changeThroughHelper()
            }
            // A user local can shadow the original observer parameter.
            let incoming = "local"
            _ = incoming
        }
        didSet(previous) {
            oldValues.append(previous)
            if value < 0 { self.value = 0 }
        }
    }
    public init() {}
    private mutating func changeThroughHelper() { value = 1 }
}

@FeatureState
public struct WhereFixture<Value>: Sendable where Value: Equatable & Sendable {
    public var value: Value
}

@FeatureState
public enum EscapedFixture: Equatable, Sendable {
    case `default`(FixtureChild)
    case none
}

@FeatureState
public struct OuterNestedFixture: Sendable {
    @FeatureState
    public struct Child: Sendable { public var value: Int = 0 }
    public var child: Child = Child()
}

// This probe deliberately has no Equatable conformance: the nominal state's
// custom witness must be used, not an accidentally synthesized replacement.
nonisolated public final class FixtureEqualityProbe: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)
    public init() {}
    public func increment() { storage.withLock { $0 += 1 } }
    public var count: Int { storage.withLock { $0 } }
}

@FeatureState
public struct FixtureNominalEquality: Equatable, Sendable {
    public var value: Int
    @Domain public let probe: FixtureEqualityProbe

    public init(value: Int, probe: FixtureEqualityProbe = FixtureEqualityProbe()) {
        self.value = value
        self.probe = probe
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.probe.increment()
        return lhs.value == rhs.value
    }
}

@FeatureState
public struct ConditionalHelpersFixture: Sendable {
    public var value: Int = 0
    #if os(macOS)
    public static func helper() -> Int { 1 }
    #endif
}
