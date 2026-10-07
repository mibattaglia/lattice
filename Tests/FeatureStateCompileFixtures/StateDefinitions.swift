import Lattice
import IdentifiedCollections

@FeatureState
public struct FixtureChild: Equatable, Sendable {
    public var title: String = "Visible"
    @Domain public var secret: Int = 7
    private var privateValue: Int = 0
    fileprivate var fileValue: Int = 0
}

@FeatureState
public struct FixtureRoot<Value: Equatable> {
    public var value: Value
    public var child: FixtureChild = FixtureChild()
    public var optional: FixtureChild? = FixtureChild()
    public var phase: FixturePhase = .ready(FixtureChild())
    public var rows: IdentifiedArrayOf<FixtureRow> = []
    var moduleOnly: String = "Internal"
    package var packageOnly: String = "Package"
    public private(set) var readOnly: Int = 42
}

@FeatureState
public enum FixturePhase: Equatable, Sendable {
    case idle
    case ready(FixtureChild)
}

@FeatureState
public struct FixtureRow: Equatable, Identifiable, Sendable {
    public var id: Int
    public var title: String
    @Domain public var secret: Int = 7
}

public struct FixtureOuter<Value: Equatable> {
    @FeatureState
    public struct Inner {
        public var value: Value
        public var `default`: Int = 0
        @Domain public var raw: String = ""
        public var label: String { raw }
    }
}

@available(macOS 14, iOS 17, watchOS 10, *)
@FeatureState
public struct AvailableFixture {
    public var value: Int = 0
}

@FeatureState
public struct SelfFixture: Equatable {
    public var value: Int = 0
    @Domain public var hidden: Int = 0
    public var copy: Self { self }
}

@FeatureState
public struct ExplicitFixture: FeatureStateProtocol {
    public var value: Int = 0
}

@FeatureState
public struct GenericRow<Value: Equatable>: Identifiable, Equatable {
    public var id: Int
    public var value: Value
}

@FeatureState
public struct GenericStructures<Value: Equatable> {
    public typealias Rows = IdentifiedArrayOf<GenericRow<Value>>
    public var child: GenericRow<Value>
    public var optional: GenericRow<Value>?
    public var rows: IdentifiedArrayOf<GenericRow<Value>>
    public var computedChild: GenericRow<Value> { child }
    public var computedOptional: GenericRow<Value>? { optional }
    public var computedRows: Rows { rows }
}

@FeatureState
public struct OpaqueLeafRoot {
    public struct Leaf: Equatable { public var wholeValue: Int }
    public var value: Leaf
    public var primitives: [Int] = []
    public var optionalValue: Int? = nil
    public var observed: Int = 0 { didSet {} }
}

@FeatureState
public struct WhereFixture<Value> where Value: Equatable {
    public var value: Value
}

@FeatureState
public enum EscapedFixture: Equatable {
    case `default`(FixtureChild)
    case none
}

@FeatureState
public struct ConditionalDomainFixture {
    public var value: Int = 0
    #if os(macOS)
    @Domain public var hidden: Int = 0
    private var privateHidden: Int = 0
    #endif
}

@FeatureState
public struct OuterNestedFixture {
    @FeatureState
    public struct Child { public var value: Int = 0 }
    public var child: Child = Child()
}
