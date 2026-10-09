import Lattice
import CasePaths
import IdentifiedCollections

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
