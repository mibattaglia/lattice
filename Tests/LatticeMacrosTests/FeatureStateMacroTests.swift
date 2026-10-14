#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import SwiftSyntaxMacroExpansion
    import SwiftSyntaxMacros
    import SwiftSyntaxMacrosTestSupport
    import XCTest

    final class FeatureStateMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(
                macros: [
                    // The extension role only runs when the expansion is told which
                    // conformances are missing.
                    "FeatureState": MacroSpec(
                        type: FeatureStateMacro.self,
                        conformances: ["Lattice.FeatureState", "Observation.Observable"]
                    ),
                    "ObservationStateTracked": MacroSpec(type: ObservationStateTrackedMacro.self),
                    "ObservationStateIgnored": MacroSpec(type: ObservationStateIgnoredMacro.self),
                    "Domain": MacroSpec(type: DomainMacro.self),
                ]
            ) {
                super.invokeTest()
            }
        }

        func testAvailability() {
            assertMacro {
                """
                @FeatureState
                @available(iOS 18, *)
                struct State {
                  var count = 0
                }
                """
            } expansion: {
                #"""
                @available(iOS 18, *)
                struct State {
                  var count {
                    @storageRestrictions(initializes: _count)
                    init(initialValue) {
                      _count = initialValue
                    }
                    get {
                      _$observationRegistrar.access(self, keyPath: \.count)
                      return _count
                    }
                    set {
                      _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                    }
                    _modify {
                      let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                      defer {
                        _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                      }
                      yield &_count
                    }
                  }

                  var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                  public var _$id: Lattice.ObservableStateID {
                    _$observationRegistrar.id
                  }

                  public mutating func _$willModify() {
                    _$observationRegistrar._$willModify()
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                    true
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                    lhs != rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                    lhs !== rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                    lhs != rhs
                  }

                  protocol _$ViewStateTypes {
                    associatedtype count
                    var _$count: count {
                      get
                    }
                  }

                  struct _$ViewStateWitness: _$ViewStateTypes {
                    let _$count = Lattice._$project(Lattice._$placeholder(State.self).count)
                  }

                  @available(iOS 18, *)
                  @Lattice._IdentifiableIfPossible(State.self)
                  @Lattice._EquatableIfPossible(State.self)
                  struct ViewState: Lattice.ViewStateProjection {
                    @_spi(Lattice) public let _state: State
                    init(_ state: State) {
                      self._state = state
                    }
                    var count: _$ViewStateWitness.count {
                      Lattice._$project(_state.count)
                    }
                  }
                }

                @available(iOS 18, *) extension State: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testFeatureState() throws {
            assertMacro {
                #"""
                @FeatureState
                struct State {
                  var count = 0
                }
                """#
            } expansion: {
                #"""
                struct State {
                  var count {
                    @storageRestrictions(initializes: _count)
                    init(initialValue) {
                      _count = initialValue
                    }
                    get {
                      _$observationRegistrar.access(self, keyPath: \.count)
                      return _count
                    }
                    set {
                      _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                    }
                    _modify {
                      let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                      defer {
                        _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                      }
                      yield &_count
                    }
                  }

                  var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                  public var _$id: Lattice.ObservableStateID {
                    _$observationRegistrar.id
                  }

                  public mutating func _$willModify() {
                    _$observationRegistrar._$willModify()
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                    true
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                    lhs != rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                    lhs !== rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                    lhs != rhs
                  }

                  protocol _$ViewStateTypes {
                    associatedtype count
                    var _$count: count {
                      get
                    }
                  }

                  struct _$ViewStateWitness: _$ViewStateTypes {
                    let _$count = Lattice._$project(Lattice._$placeholder(State.self).count)
                  }

                  @Lattice._IdentifiableIfPossible(State.self)
                  @Lattice._EquatableIfPossible(State.self)
                  struct ViewState: Lattice.ViewStateProjection {
                    @_spi(Lattice) public let _state: State
                    init(_ state: State) {
                      self._state = state
                    }
                    var count: _$ViewStateWitness.count {
                      Lattice._$project(_state.count)
                    }
                  }
                }

                extension State: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testFeatureState_AccessControl() throws {
            assertMacro {
                #"""
                @FeatureState
                public struct State {
                  var count = 0
                }
                """#
            } expansion: {
                #"""
                public struct State {
                  var count {
                    @storageRestrictions(initializes: _count)
                    init(initialValue) {
                      _count = initialValue
                    }
                    get {
                      _$observationRegistrar.access(self, keyPath: \.count)
                      return _count
                    }
                    set {
                      _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                    }
                    _modify {
                      let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                      defer {
                        _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                      }
                      yield &_count
                    }
                  }

                  var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                  public var _$id: Lattice.ObservableStateID {
                    _$observationRegistrar.id
                  }

                  public mutating func _$willModify() {
                    _$observationRegistrar._$willModify()
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                    true
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                    lhs != rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                    lhs !== rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                    lhs != rhs
                  }

                  public protocol _$ViewStateTypes {
                    associatedtype count
                    var _$count: count {
                      get
                    }
                  }

                  public struct _$ViewStateWitness: _$ViewStateTypes {
                    public let _$count = Lattice._$project(Lattice._$placeholder(State.self).count)
                  }

                  @Lattice._IdentifiableIfPossible(State.self)
                  @Lattice._EquatableIfPossible(State.self)
                  public struct ViewState: Lattice.ViewStateProjection {
                    @_spi(Lattice) public let _state: State
                    public init(_ state: State) {
                      self._state = state
                    }
                    public var count: _$ViewStateWitness.count {
                      Lattice._$project(_state.count)
                    }
                  }
                }

                extension State: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
            assertMacro {
                #"""
                @FeatureState
                package struct State {
                  var count = 0
                }
                """#
            } expansion: {
                #"""
                package struct State {
                  var count {
                    @storageRestrictions(initializes: _count)
                    init(initialValue) {
                      _count = initialValue
                    }
                    get {
                      _$observationRegistrar.access(self, keyPath: \.count)
                      return _count
                    }
                    set {
                      _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                    }
                    _modify {
                      let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                      defer {
                        _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                      }
                      yield &_count
                    }
                  }

                  var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                  public var _$id: Lattice.ObservableStateID {
                    _$observationRegistrar.id
                  }

                  public mutating func _$willModify() {
                    _$observationRegistrar._$willModify()
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                    true
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                    lhs != rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                    lhs !== rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                    lhs != rhs
                  }

                  package protocol _$ViewStateTypes {
                    associatedtype count
                    var _$count: count {
                      get
                    }
                  }

                  package struct _$ViewStateWitness: _$ViewStateTypes {
                    package let _$count = Lattice._$project(Lattice._$placeholder(State.self).count)
                  }

                  @Lattice._IdentifiableIfPossible(State.self)
                  @Lattice._EquatableIfPossible(State.self)
                  package struct ViewState: Lattice.ViewStateProjection {
                    @_spi(Lattice) public let _state: State
                    package init(_ state: State) {
                      self._state = state
                    }
                    package var count: _$ViewStateWitness.count {
                      Lattice._$project(_state.count)
                    }
                  }
                }

                extension State: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testFeatureStateIgnored() throws {
            assertMacro {
                #"""
                @FeatureState
                struct State {
                  @ObservationStateIgnored
                  var count = 0
                }
                """#
            } expansion: {
                """
                struct State {
                  var count = 0

                  var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                  public var _$id: Lattice.ObservableStateID {
                    _$observationRegistrar.id
                  }

                  public mutating func _$willModify() {
                    _$observationRegistrar._$willModify()
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                    true
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                    lhs != rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                    lhs !== rhs
                  }

                  private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                    lhs != rhs
                  }

                  protocol _$ViewStateTypes {
                    associatedtype count
                    var _$count: count {
                      get
                    }
                  }

                  struct _$ViewStateWitness: _$ViewStateTypes {
                    let _$count = Lattice._$project(Lattice._$placeholder(State.self).count)
                  }

                  @Lattice._IdentifiableIfPossible(State.self)
                  @Lattice._EquatableIfPossible(State.self)
                  struct ViewState: Lattice.ViewStateProjection {
                    @_spi(Lattice) public let _state: State
                    init(_ state: State) {
                      self._state = state
                    }
                    var count: _$ViewStateWitness.count {
                      Lattice._$project(_state.count)
                    }
                  }
                }

                extension State: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        func testFeatureState_Enum() {
            assertMacro {
                """
                @FeatureState
                enum Path {
                  case feature1(Feature1.State)
                  case feature2(Feature2.State)
                }
                """
            } expansion: {
                """
                enum Path {
                  case feature1(Feature1.State)
                  case feature2(Feature2.State)

                  public var _$id: Lattice.ObservableStateID {
                    switch self {
                    case let .feature1(state):
                      return ._$id(for: state)._$tag(0)
                    case let .feature2(state):
                      return ._$id(for: state)._$tag(1)
                    }
                  }

                  public mutating func _$willModify() {
                    switch self {
                    case var .feature1(state):
                      Lattice._$willModify(&state)
                      self = .feature1(state)
                    case var .feature2(state):
                      Lattice._$willModify(&state)
                      self = .feature2(state)
                    }
                  }

                  protocol _$ViewStateTypes {
                    associatedtype feature1_0
                    var _$feature1_0: feature1_0 {
                      get
                    }
                    associatedtype feature2_0
                    var _$feature2_0: feature2_0 {
                      get
                    }
                  }

                  struct _$ViewStateWitness: _$ViewStateTypes {
                    let _$feature1_0 = Lattice._$project(Lattice._$placeholder((Feature1.State).self))
                    let _$feature2_0 = Lattice._$project(Lattice._$placeholder((Feature2.State).self))
                  }

                  @Lattice._IdentifiableIfPossible(Path.self)
                  @Lattice._EquatableIfPossible(Path.self)
                  enum ViewState: Lattice.ViewStateProjection {
                    case feature1(_$ViewStateWitness.feature1_0)
                    case feature2(_$ViewStateWitness.feature2_0)
                    init(_ state: Path) {
                      switch state {
                      case let .feature1(p0):
                        self = .feature1(Lattice._$project(p0))
                      case let .feature2(p0):
                        self = .feature2(Lattice._$project(p0))
                      }
                    }
                    @_spi(Lattice) public var _state: Path {
                      switch self {
                      case let .feature1(p0):
                        return .feature1(Lattice._$unproject(p0, to: (Feature1.State).self))
                      case let .feature2(p0):
                        return .feature2(Lattice._$unproject(p0, to: (Feature2.State).self))
                      }
                    }
                  }
                }

                extension Path: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        func testFeatureState_Enum_Label() {
            assertMacro {
                """
                @FeatureState
                enum Path {
                  case feature1(state: String)
                }
                """
            } expansion: {
                """
                enum Path {
                  case feature1(state: String)

                  public var _$id: Lattice.ObservableStateID {
                    switch self {
                    case let .feature1(state):
                      return ._$id(for: state)._$tag(0)
                    }
                  }

                  public mutating func _$willModify() {
                    switch self {
                    case var .feature1(state):
                      Lattice._$willModify(&state)
                      self = .feature1(state: state)
                    }
                  }

                  protocol _$ViewStateTypes {
                    associatedtype feature1_0
                    var _$feature1_0: feature1_0 {
                      get
                    }
                  }

                  struct _$ViewStateWitness: _$ViewStateTypes {
                    let _$feature1_0 = Lattice._$project(Lattice._$placeholder((String).self))
                  }

                  @Lattice._IdentifiableIfPossible(Path.self)
                  @Lattice._EquatableIfPossible(Path.self)
                  enum ViewState: Lattice.ViewStateProjection {
                    case feature1(state: _$ViewStateWitness.feature1_0)
                    init(_ state: Path) {
                      switch state {
                      case let .feature1(p0):
                        self = .feature1(state: Lattice._$project(p0))
                      }
                    }
                    @_spi(Lattice) public var _state: Path {
                      switch self {
                      case let .feature1(p0):
                        return .feature1(state: Lattice._$unproject(p0, to: (String).self))
                      }
                    }
                  }
                }

                extension Path: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        func testFeatureState_Enum_AccessControl() {
            assertMacro {
                """
                @FeatureState
                public enum Path {
                  case feature1(Feature1.State)
                  case feature2(Feature2.State)
                }
                """
            } expansion: {
                """
                public enum Path {
                  case feature1(Feature1.State)
                  case feature2(Feature2.State)

                  public var _$id: Lattice.ObservableStateID {
                    switch self {
                    case let .feature1(state):
                      return ._$id(for: state)._$tag(0)
                    case let .feature2(state):
                      return ._$id(for: state)._$tag(1)
                    }
                  }

                  public mutating func _$willModify() {
                    switch self {
                    case var .feature1(state):
                      Lattice._$willModify(&state)
                      self = .feature1(state)
                    case var .feature2(state):
                      Lattice._$willModify(&state)
                      self = .feature2(state)
                    }
                  }

                  public protocol _$ViewStateTypes {
                    associatedtype feature1_0
                    var _$feature1_0: feature1_0 {
                      get
                    }
                    associatedtype feature2_0
                    var _$feature2_0: feature2_0 {
                      get
                    }
                  }

                  public struct _$ViewStateWitness: _$ViewStateTypes {
                    public let _$feature1_0 = Lattice._$project(Lattice._$placeholder((Feature1.State).self))
                    public let _$feature2_0 = Lattice._$project(Lattice._$placeholder((Feature2.State).self))
                  }

                  @Lattice._IdentifiableIfPossible(Path.self)
                  @Lattice._EquatableIfPossible(Path.self)
                  public enum ViewState: Lattice.ViewStateProjection {
                    case feature1(_$ViewStateWitness.feature1_0)
                    case feature2(_$ViewStateWitness.feature2_0)
                    public init(_ state: Path) {
                      switch state {
                      case let .feature1(p0):
                        self = .feature1(Lattice._$project(p0))
                      case let .feature2(p0):
                        self = .feature2(Lattice._$project(p0))
                      }
                    }
                    @_spi(Lattice) public var _state: Path {
                      switch self {
                      case let .feature1(p0):
                        return .feature1(Lattice._$unproject(p0, to: (Feature1.State).self))
                      case let .feature2(p0):
                        return .feature2(Lattice._$unproject(p0, to: (Feature2.State).self))
                      }
                    }
                  }
                }

                extension Path: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
            assertMacro {
                """
                @FeatureState
                package enum Path {
                  case feature1(Feature1.State)
                  case feature2(Feature2.State)
                }
                """
            } expansion: {
                """
                package enum Path {
                  case feature1(Feature1.State)
                  case feature2(Feature2.State)

                  public var _$id: Lattice.ObservableStateID {
                    switch self {
                    case let .feature1(state):
                      return ._$id(for: state)._$tag(0)
                    case let .feature2(state):
                      return ._$id(for: state)._$tag(1)
                    }
                  }

                  public mutating func _$willModify() {
                    switch self {
                    case var .feature1(state):
                      Lattice._$willModify(&state)
                      self = .feature1(state)
                    case var .feature2(state):
                      Lattice._$willModify(&state)
                      self = .feature2(state)
                    }
                  }

                  package protocol _$ViewStateTypes {
                    associatedtype feature1_0
                    var _$feature1_0: feature1_0 {
                      get
                    }
                    associatedtype feature2_0
                    var _$feature2_0: feature2_0 {
                      get
                    }
                  }

                  package struct _$ViewStateWitness: _$ViewStateTypes {
                    package let _$feature1_0 = Lattice._$project(Lattice._$placeholder((Feature1.State).self))
                    package let _$feature2_0 = Lattice._$project(Lattice._$placeholder((Feature2.State).self))
                  }

                  @Lattice._IdentifiableIfPossible(Path.self)
                  @Lattice._EquatableIfPossible(Path.self)
                  package enum ViewState: Lattice.ViewStateProjection {
                    case feature1(_$ViewStateWitness.feature1_0)
                    case feature2(_$ViewStateWitness.feature2_0)
                    package init(_ state: Path) {
                      switch state {
                      case let .feature1(p0):
                        self = .feature1(Lattice._$project(p0))
                      case let .feature2(p0):
                        self = .feature2(Lattice._$project(p0))
                      }
                    }
                    @_spi(Lattice) public var _state: Path {
                      switch self {
                      case let .feature1(p0):
                        return .feature1(Lattice._$unproject(p0, to: (Feature1.State).self))
                      case let .feature2(p0):
                        return .feature2(Lattice._$unproject(p0, to: (Feature2.State).self))
                      }
                    }
                  }
                }

                extension Path: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        func testFeatureState_Enum_AccessControl_WrappedByExtension() {
            assertMacro {
                """
                public extension Feature {
                  @FeatureState
                  enum Path {
                    case feature1(Feature1.State)
                    case feature2(Feature2.State)
                  }
                }
                """
            } expansion: {
                """
                public extension Feature {
                  enum Path {
                    case feature1(Feature1.State)
                    case feature2(Feature2.State)

                    public var _$id: Lattice.ObservableStateID {
                      switch self {
                      case let .feature1(state):
                        return ._$id(for: state)._$tag(0)
                      case let .feature2(state):
                        return ._$id(for: state)._$tag(1)
                      }
                    }

                    public mutating func _$willModify() {
                      switch self {
                      case var .feature1(state):
                        Lattice._$willModify(&state)
                        self = .feature1(state)
                      case var .feature2(state):
                        Lattice._$willModify(&state)
                        self = .feature2(state)
                      }
                    }

                    public protocol _$ViewStateTypes {
                      associatedtype feature1_0
                      var _$feature1_0: feature1_0 {
                        get
                      }
                      associatedtype feature2_0
                      var _$feature2_0: feature2_0 {
                        get
                      }
                    }

                    public struct _$ViewStateWitness: _$ViewStateTypes {
                      public let _$feature1_0 = Lattice._$project(Lattice._$placeholder((Feature1.State).self))
                      public let _$feature2_0 = Lattice._$project(Lattice._$placeholder((Feature2.State).self))
                    }

                    @Lattice._IdentifiableIfPossible(Path.self)
                    @Lattice._EquatableIfPossible(Path.self)
                    public enum ViewState: Lattice.ViewStateProjection {
                      case feature1(_$ViewStateWitness.feature1_0)
                      case feature2(_$ViewStateWitness.feature2_0)
                      public init(_ state: Path) {
                        switch state {
                        case let .feature1(p0):
                          self = .feature1(Lattice._$project(p0))
                        case let .feature2(p0):
                          self = .feature2(Lattice._$project(p0))
                        }
                      }
                      @_spi(Lattice) public var _state: Path {
                        switch self {
                        case let .feature1(p0):
                          return .feature1(Lattice._$unproject(p0, to: (Feature1.State).self))
                        case let .feature2(p0):
                          return .feature2(Lattice._$unproject(p0, to: (Feature2.State).self))
                        }
                      }
                    }
                  }
                }

                extension Feature.Path: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
            assertMacro {
                """
                public extension Feature {
                  @FeatureState
                  package enum Path {
                    case feature1(Feature1.State)
                    case feature2(Feature2.State)
                  }
                }
                """
            } expansion: {
                """
                public extension Feature {
                  package enum Path {
                    case feature1(Feature1.State)
                    case feature2(Feature2.State)

                    public var _$id: Lattice.ObservableStateID {
                      switch self {
                      case let .feature1(state):
                        return ._$id(for: state)._$tag(0)
                      case let .feature2(state):
                        return ._$id(for: state)._$tag(1)
                      }
                    }

                    public mutating func _$willModify() {
                      switch self {
                      case var .feature1(state):
                        Lattice._$willModify(&state)
                        self = .feature1(state)
                      case var .feature2(state):
                        Lattice._$willModify(&state)
                        self = .feature2(state)
                      }
                    }

                    package protocol _$ViewStateTypes {
                      associatedtype feature1_0
                      var _$feature1_0: feature1_0 {
                        get
                      }
                      associatedtype feature2_0
                      var _$feature2_0: feature2_0 {
                        get
                      }
                    }

                    package struct _$ViewStateWitness: _$ViewStateTypes {
                      package let _$feature1_0 = Lattice._$project(Lattice._$placeholder((Feature1.State).self))
                      package let _$feature2_0 = Lattice._$project(Lattice._$placeholder((Feature2.State).self))
                    }

                    @Lattice._IdentifiableIfPossible(Path.self)
                    @Lattice._EquatableIfPossible(Path.self)
                    package enum ViewState: Lattice.ViewStateProjection {
                      case feature1(_$ViewStateWitness.feature1_0)
                      case feature2(_$ViewStateWitness.feature2_0)
                      package init(_ state: Path) {
                        switch state {
                        case let .feature1(p0):
                          self = .feature1(Lattice._$project(p0))
                        case let .feature2(p0):
                          self = .feature2(Lattice._$project(p0))
                        }
                      }
                      @_spi(Lattice) public var _state: Path {
                        switch self {
                        case let .feature1(p0):
                          return .feature1(Lattice._$unproject(p0, to: (Feature1.State).self))
                        case let .feature2(p0):
                          return .feature2(Lattice._$unproject(p0, to: (Feature2.State).self))
                        }
                      }
                    }
                  }
                }

                extension Feature.Path: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        func testFeatureState_Enum_NonObservableCase() {
            assertMacro {
                """
                @FeatureState
                public enum Path {
                  case foo(Int)
                }
                """
            } expansion: {
                """
                public enum Path {
                  case foo(Int)

                  public var _$id: Lattice.ObservableStateID {
                    switch self {
                    case let .foo(state):
                      return ._$id(for: state)._$tag(0)
                    }
                  }

                  public mutating func _$willModify() {
                    switch self {
                    case var .foo(state):
                      Lattice._$willModify(&state)
                      self = .foo(state)
                    }
                  }

                  public protocol _$ViewStateTypes {
                    associatedtype foo_0
                    var _$foo_0: foo_0 {
                      get
                    }
                  }

                  public struct _$ViewStateWitness: _$ViewStateTypes {
                    public let _$foo_0 = Lattice._$project(Lattice._$placeholder((Int).self))
                  }

                  @Lattice._IdentifiableIfPossible(Path.self)
                  @Lattice._EquatableIfPossible(Path.self)
                  public enum ViewState: Lattice.ViewStateProjection {
                    case foo(_$ViewStateWitness.foo_0)
                    public init(_ state: Path) {
                      switch state {
                      case let .foo(p0):
                        self = .foo(Lattice._$project(p0))
                      }
                    }
                    @_spi(Lattice) public var _state: Path {
                      switch self {
                      case let .foo(p0):
                        return .foo(Lattice._$unproject(p0, to: (Int).self))
                      }
                    }
                  }
                }

                extension Path: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        func testFeatureState_Enum_MultipleAssociatedValues() {
            assertMacro {
                """
                @FeatureState
                public enum Path {
                  case foo(Int, String)
                }
                """
            } expansion: {
                """
                public enum Path {
                  case foo(Int, String)

                  public var _$id: Lattice.ObservableStateID {
                    switch self {
                    case .foo:
                      return ObservableStateID._$inert._$tag(0)
                    }
                  }

                  public mutating func _$willModify() {
                    switch self {
                    case .foo:
                      break
                    }
                  }

                  public protocol _$ViewStateTypes {
                    associatedtype foo_0
                    var _$foo_0: foo_0 {
                      get
                    }
                    associatedtype foo_1
                    var _$foo_1: foo_1 {
                      get
                    }
                  }

                  public struct _$ViewStateWitness: _$ViewStateTypes {
                    public let _$foo_0 = Lattice._$project(Lattice._$placeholder((Int).self))
                    public let _$foo_1 = Lattice._$project(Lattice._$placeholder((String).self))
                  }

                  @Lattice._IdentifiableIfPossible(Path.self)
                  @Lattice._EquatableIfPossible(Path.self)
                  public enum ViewState: Lattice.ViewStateProjection {
                    case foo(_$ViewStateWitness.foo_0, _$ViewStateWitness.foo_1)
                    public init(_ state: Path) {
                      switch state {
                      case let .foo(p0, p1):
                        self = .foo(Lattice._$project(p0), Lattice._$project(p1))
                      }
                    }
                    @_spi(Lattice) public var _state: Path {
                      switch self {
                      case let .foo(p0, p1):
                        return .foo(Lattice._$unproject(p0, to: (Int).self), Lattice._$unproject(p1, to: (String).self))
                      }
                    }
                  }
                }

                extension Path: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        func testFeatureState_Class() {
            assertMacro {
                """
                @FeatureState
                public class Model {
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 '@FeatureState' cannot be applied to class type 'Model'
                public class Model {
                }
                """
            }
        }

        func testFeatureState_Actor() {
            assertMacro {
                """
                @FeatureState
                public actor Model {
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 '@FeatureState' cannot be applied to actor type 'Model'
                public actor Model {
                }
                """
            }
        }

        func testFeatureState_Enum_IfConfig() {
            assertMacro {
                """
                @FeatureState
                public enum State {
                  case child(ChildFeature.State)
                  #if os(macOS)
                    case mac(MacFeature.State)
                  #elseif os(tvOS)
                    case tv(TVFeature.State)
                  #endif

                  #if DEBUG
                    #if INNER
                      case inner(InnerFeature.State)
                    #endif
                  #endif
                }
                """
            } expansion: {
                """
                public enum State {
                  case child(ChildFeature.State)
                  #if os(macOS)
                    case mac(MacFeature.State)
                  #elseif os(tvOS)
                    case tv(TVFeature.State)
                  #endif

                  #if DEBUG
                    #if INNER
                      case inner(InnerFeature.State)
                    #endif
                  #endif

                  public var _$id: Lattice.ObservableStateID {
                    switch self {
                    case let .child(state):
                      return ._$id(for: state)._$tag(0)
                    #if os(macOS)
                    case let .mac(state):
                      return ._$id(for: state)._$tag(1)
                    #elseif os(tvOS)
                    case let .tv(state):
                      return ._$id(for: state)._$tag(2)
                    #endif

                    #if DEBUG
                    #if INNER
                    case let .inner(state):
                      return ._$id(for: state)._$tag(3)
                    #endif
                    #endif

                    }
                  }

                  public mutating func _$willModify() {
                    switch self {
                    case var .child(state):
                      Lattice._$willModify(&state)
                      self = .child(state)
                    #if os(macOS)
                    case var .mac(state):
                      Lattice._$willModify(&state)
                      self = .mac(state)
                    #elseif os(tvOS)
                    case var .tv(state):
                      Lattice._$willModify(&state)
                      self = .tv(state)
                    #endif

                    #if DEBUG
                    #if INNER
                    case var .inner(state):
                      Lattice._$willModify(&state)
                      self = .inner(state)
                    #endif
                    #endif

                    }
                  }

                  public protocol _$ViewStateTypes {
                    associatedtype child_0
                    var _$child_0: child_0 {
                      get
                    }
                    #if os(macOS)
                    associatedtype mac_0
                    var _$mac_0: mac_0 {
                      get
                    }
                    #elseif os(tvOS)
                    associatedtype tv_0
                    var _$tv_0: tv_0 {
                      get
                    }
                    #endif
                    #if DEBUG
                    #if INNER
                    associatedtype inner_0
                    var _$inner_0: inner_0 {
                      get
                    }
                    #endif
                    #endif
                  }

                  public struct _$ViewStateWitness: _$ViewStateTypes {
                    public let _$child_0 = Lattice._$project(Lattice._$placeholder((ChildFeature.State).self))
                    #if os(macOS)
                    public let _$mac_0 = Lattice._$project(Lattice._$placeholder((MacFeature.State).self))
                    #elseif os(tvOS)
                    public let _$tv_0 = Lattice._$project(Lattice._$placeholder((TVFeature.State).self))
                    #endif
                    #if DEBUG
                    #if INNER
                    public let _$inner_0 = Lattice._$project(Lattice._$placeholder((InnerFeature.State).self))
                    #endif
                    #endif
                  }

                  @Lattice._IdentifiableIfPossible(State.self)
                  @Lattice._EquatableIfPossible(State.self)
                  public enum ViewState: Lattice.ViewStateProjection {
                    case child(_$ViewStateWitness.child_0)
                    #if os(macOS)
                    case mac(_$ViewStateWitness.mac_0)
                    #elseif os(tvOS)
                    case tv(_$ViewStateWitness.tv_0)
                    #endif
                    #if DEBUG
                    #if INNER
                    case inner(_$ViewStateWitness.inner_0)
                    #endif
                    #endif
                    public init(_ state: State) {
                      switch state {
                      case let .child(p0):
                        self = .child(Lattice._$project(p0))
                      #if os(macOS)
                      case let .mac(p0):
                        self = .mac(Lattice._$project(p0))
                      #elseif os(tvOS)
                      case let .tv(p0):
                        self = .tv(Lattice._$project(p0))
                      #endif
                      #if DEBUG
                      #if INNER
                      case let .inner(p0):
                        self = .inner(Lattice._$project(p0))
                      #endif
                      #endif
                      }
                    }
                    @_spi(Lattice) public var _state: State {
                      switch self {
                      case let .child(p0):
                        return .child(Lattice._$unproject(p0, to: (ChildFeature.State).self))
                      #if os(macOS)
                      case let .mac(p0):
                        return .mac(Lattice._$unproject(p0, to: (MacFeature.State).self))
                      #elseif os(tvOS)
                      case let .tv(p0):
                        return .tv(Lattice._$unproject(p0, to: (TVFeature.State).self))
                      #endif
                      #if DEBUG
                      #if INNER
                      case let .inner(p0):
                        return .inner(Lattice._$unproject(p0, to: (InnerFeature.State).self))
                      #endif
                      #endif
                      }
                    }
                  }
                }

                extension State: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        // MARK: - ViewState projection

        func testViewState_Struct_EveryMemberKind() {
            assertMacro {
                """
                @FeatureState
                public struct CounterState: Equatable, Sendable {
                    public var title = "Counter"
                    @Domain public var lastUpdatedAt: Date?
                    @Domain var nonce = 0
                    public var badge = BadgeState()
                    public var detail: BadgeState?
                    public var rows: IdentifiedArrayOf<BadgeState> = []
                    public var tags: [String] = []
                    public var lastUpdatedText: String { lastUpdatedAt.map(Self.format) ?? "Never" }
                    private var scratch = 0
                }
                """
            } expansion: {
                #"""
                public struct CounterState: Equatable, Sendable {
                    public var title {
                        @storageRestrictions(initializes: _title)
                        init(initialValue) {
                            _title = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.title)
                            return _title
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.title, &_title, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.title, &_title)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.title, &_title, oldValue, _$isIdentityEqual)
                          }
                          yield &_title
                        }
                    }
                    public var lastUpdatedAt: Date? {
                        @storageRestrictions(initializes: _lastUpdatedAt)
                        init(initialValue) {
                            _lastUpdatedAt = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.lastUpdatedAt)
                            return _lastUpdatedAt
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.lastUpdatedAt, &_lastUpdatedAt, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.lastUpdatedAt, &_lastUpdatedAt)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.lastUpdatedAt, &_lastUpdatedAt, oldValue, _$isIdentityEqual)
                          }
                          yield &_lastUpdatedAt
                        }
                    }
                    var nonce {
                        @storageRestrictions(initializes: _nonce)
                        init(initialValue) {
                            _nonce = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.nonce)
                            return _nonce
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.nonce, &_nonce, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.nonce, &_nonce)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.nonce, &_nonce, oldValue, _$isIdentityEqual)
                          }
                          yield &_nonce
                        }
                    }
                    public var badge {
                        @storageRestrictions(initializes: _badge)
                        init(initialValue) {
                            _badge = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.badge)
                            return _badge
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.badge, &_badge, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.badge, &_badge)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.badge, &_badge, oldValue, _$isIdentityEqual)
                          }
                          yield &_badge
                        }
                    }
                    public var detail: BadgeState? {
                        @storageRestrictions(initializes: _detail)
                        init(initialValue) {
                            _detail = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.detail)
                            return _detail
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.detail, &_detail, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.detail, &_detail)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.detail, &_detail, oldValue, _$isIdentityEqual)
                          }
                          yield &_detail
                        }
                    }
                    public var rows: IdentifiedArrayOf<BadgeState> {
                        @storageRestrictions(initializes: _rows)
                        init(initialValue) {
                            _rows = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.rows)
                            return _rows
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.rows, &_rows, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.rows, &_rows)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.rows, &_rows, oldValue, _$isIdentityEqual)
                          }
                          yield &_rows
                        }
                    }
                    public var tags: [String] {
                        @storageRestrictions(initializes: _tags)
                        init(initialValue) {
                            _tags = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.tags)
                            return _tags
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.tags, &_tags, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.tags, &_tags)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.tags, &_tags, oldValue, _$isIdentityEqual)
                          }
                          yield &_tags
                        }
                    }
                    public var lastUpdatedText: String { lastUpdatedAt.map(Self.format) ?? "Never" }
                    private var scratch {
                        @storageRestrictions(initializes: _scratch)
                        init(initialValue) {
                            _scratch = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.scratch)
                            return _scratch
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.scratch, &_scratch, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.scratch, &_scratch)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.scratch, &_scratch, oldValue, _$isIdentityEqual)
                          }
                          yield &_scratch
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    public protocol _$ViewStateTypes {
                        associatedtype title
                        var _$title: title {
                            get
                        }
                        associatedtype nonce
                        var _$nonce: nonce {
                            get
                        }
                        associatedtype badge
                        var _$badge: badge {
                            get
                        }
                        associatedtype detail
                        var _$detail: detail {
                            get
                        }
                        associatedtype rows
                        var _$rows: rows {
                            get
                        }
                        associatedtype tags
                        var _$tags: tags {
                            get
                        }
                        associatedtype lastUpdatedText
                        var _$lastUpdatedText: lastUpdatedText {
                            get
                        }
                    }

                    public struct _$ViewStateWitness: _$ViewStateTypes {
                        public let _$title = Lattice._$project(Lattice._$placeholder(CounterState.self).title)
                        public let _$nonce = Lattice._$placeholder(CounterState.self).nonce
                        public let _$badge = Lattice._$project(Lattice._$placeholder(CounterState.self).badge)
                        public let _$detail = Lattice._$project(Lattice._$placeholder(CounterState.self).detail)
                        public let _$rows = Lattice._$project(Lattice._$placeholder(CounterState.self).rows)
                        public let _$tags = Lattice._$project(Lattice._$placeholder(CounterState.self).tags)
                        public let _$lastUpdatedText = Lattice._$project(Lattice._$placeholder(CounterState.self).lastUpdatedText)
                    }

                    @Lattice._IdentifiableIfPossible(CounterState.self)
                    @Lattice._EquatableIfPossible(CounterState.self)
                    public struct ViewState: Lattice.ViewStateProjection, Sendable {
                        @_spi(Lattice) public let _state: CounterState
                        public init(_ state: CounterState) {
                            self._state = state
                        }
                        public var title: _$ViewStateWitness.title {
                            Lattice._$project(_state.title)
                        }
                        public var badge: _$ViewStateWitness.badge {
                            Lattice._$project(_state.badge)
                        }
                        public var detail: _$ViewStateWitness.detail {
                            Lattice._$project(_state.detail)
                        }
                        public var rows: _$ViewStateWitness.rows {
                            Lattice._$project(_state.rows)
                        }
                        public var tags: _$ViewStateWitness.tags {
                            Lattice._$project(_state.tags)
                        }
                        public var lastUpdatedText: _$ViewStateWitness.lastUpdatedText {
                            Lattice._$project(_state.lastUpdatedText)
                        }
                        @available(*, unavailable, message: "'lastUpdatedAt' is @Domain state and is not visible to views")
                        public var lastUpdatedAt: Date? {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'nonce' is @Domain state and is not visible to views")
                        public var nonce: _$ViewStateWitness.nonce {
                            fatalError()
                        }
                    }
                }

                extension CounterState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_MemberVisibility() {
            // Multi-binding `let`s project per binding. (A multi-binding `var` is rejected by the
            // observation accessor macro, which supports a single variable per declaration.)
            assertMacro {
                """
                @propertyWrapper
                struct Boxed<T> {
                    var wrappedValue: T
                }

                @FeatureState
                struct VisibilityState {
                    let id: Int
                    let first = 0, second = 1
                    private(set) var readOnly = 2
                    fileprivate(set) var fileReadOnly = 3
                    @ObservationStateIgnored @Boxed var wrapped: Int
                    @ObservationStateIgnored var ignored = 4
                    var computed: Int { first + second }
                    private var hidden = 5
                    fileprivate var fileHidden = 6
                    static var staticValue = 7
                    static let staticConstant = 8
                    func method() {}
                    struct Nested {}
                }
                """
            } expansion: {
                #"""
                @propertyWrapper
                struct Boxed<T> {
                    var wrappedValue: T
                }
                struct VisibilityState {
                    let id: Int
                    let first = 0, second = 1
                    private(set) var readOnly {
                        @storageRestrictions(initializes: _readOnly)
                        init(initialValue) {
                            _readOnly = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.readOnly)
                            return _readOnly
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.readOnly, &_readOnly, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.readOnly, &_readOnly)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.readOnly, &_readOnly, oldValue, _$isIdentityEqual)
                          }
                          yield &_readOnly
                        }
                    }
                    fileprivate(set) var fileReadOnly {
                        @storageRestrictions(initializes: _fileReadOnly)
                        init(initialValue) {
                            _fileReadOnly = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.fileReadOnly)
                            return _fileReadOnly
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.fileReadOnly, &_fileReadOnly, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.fileReadOnly, &_fileReadOnly)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.fileReadOnly, &_fileReadOnly, oldValue, _$isIdentityEqual)
                          }
                          yield &_fileReadOnly
                        }
                    }
                    @Boxed var wrapped: Int
                    var ignored = 4
                    var computed: Int { first + second }
                    private var hidden {
                        @storageRestrictions(initializes: _hidden)
                        init(initialValue) {
                            _hidden = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.hidden)
                            return _hidden
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.hidden, &_hidden, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.hidden, &_hidden)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.hidden, &_hidden, oldValue, _$isIdentityEqual)
                          }
                          yield &_hidden
                        }
                    }
                    fileprivate var fileHidden {
                        @storageRestrictions(initializes: _fileHidden)
                        init(initialValue) {
                            _fileHidden = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.fileHidden)
                            return _fileHidden
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.fileHidden, &_fileHidden, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.fileHidden, &_fileHidden)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.fileHidden, &_fileHidden, oldValue, _$isIdentityEqual)
                          }
                          yield &_fileHidden
                        }
                    }
                    static var staticValue = 7
                    static let staticConstant = 8
                    func method() {}
                    struct Nested {}

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype id
                        var _$id: id {
                            get
                        }
                        associatedtype first
                        var _$first: first {
                            get
                        }
                        associatedtype second
                        var _$second: second {
                            get
                        }
                        associatedtype readOnly
                        var _$readOnly: readOnly {
                            get
                        }
                        associatedtype fileReadOnly
                        var _$fileReadOnly: fileReadOnly {
                            get
                        }
                        associatedtype wrapped
                        var _$wrapped: wrapped {
                            get
                        }
                        associatedtype ignored
                        var _$ignored: ignored {
                            get
                        }
                        associatedtype computed
                        var _$computed: computed {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$id = Lattice._$project(Lattice._$placeholder(VisibilityState.self).id)
                        let _$first = Lattice._$project(Lattice._$placeholder(VisibilityState.self).first)
                        let _$second = Lattice._$project(Lattice._$placeholder(VisibilityState.self).second)
                        let _$readOnly = Lattice._$project(Lattice._$placeholder(VisibilityState.self).readOnly)
                        let _$fileReadOnly = Lattice._$project(Lattice._$placeholder(VisibilityState.self).fileReadOnly)
                        let _$wrapped = Lattice._$project(Lattice._$placeholder(VisibilityState.self).wrapped)
                        let _$ignored = Lattice._$project(Lattice._$placeholder(VisibilityState.self).ignored)
                        let _$computed = Lattice._$project(Lattice._$placeholder(VisibilityState.self).computed)
                    }

                    @Lattice._IdentifiableIfPossible(VisibilityState.self)
                    @Lattice._EquatableIfPossible(VisibilityState.self)
                    struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: VisibilityState
                        init(_ state: VisibilityState) {
                            self._state = state
                        }
                        var id: _$ViewStateWitness.id {
                            Lattice._$project(_state.id)
                        }
                        var first: _$ViewStateWitness.first {
                            Lattice._$project(_state.first)
                        }
                        var second: _$ViewStateWitness.second {
                            Lattice._$project(_state.second)
                        }
                        var readOnly: _$ViewStateWitness.readOnly {
                            Lattice._$project(_state.readOnly)
                        }
                        var fileReadOnly: _$ViewStateWitness.fileReadOnly {
                            Lattice._$project(_state.fileReadOnly)
                        }
                        var wrapped: _$ViewStateWitness.wrapped {
                            Lattice._$project(_state.wrapped)
                        }
                        var ignored: _$ViewStateWitness.ignored {
                            Lattice._$project(_state.ignored)
                        }
                        var computed: _$ViewStateWitness.computed {
                            Lattice._$project(_state.computed)
                        }
                    }
                }

                extension VisibilityState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_DomainTypedAndInferred() {
            assertMacro {
                """
                @FeatureState
                struct SessionState {
                    @Domain var token: String?
                    @Domain var attempts = 0
                    @Lattice.Domain let createdAt: Date
                    @Domain var isExpired: Bool { token == nil }
                    var name = ""
                }
                """
            } expansion: {
                #"""
                struct SessionState {
                    var token: String? {
                        @storageRestrictions(initializes: _token)
                        init(initialValue) {
                            _token = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.token)
                            return _token
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.token, &_token, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.token, &_token)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.token, &_token, oldValue, _$isIdentityEqual)
                          }
                          yield &_token
                        }
                    }
                    var attempts {
                        @storageRestrictions(initializes: _attempts)
                        init(initialValue) {
                            _attempts = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.attempts)
                            return _attempts
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.attempts, &_attempts, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.attempts, &_attempts)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.attempts, &_attempts, oldValue, _$isIdentityEqual)
                          }
                          yield &_attempts
                        }
                    }
                    @Lattice.Domain let createdAt: Date
                    var isExpired: Bool { token == nil }
                    var name {
                        @storageRestrictions(initializes: _name)
                        init(initialValue) {
                            _name = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.name)
                            return _name
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.name, &_name, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.name, &_name)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.name, &_name, oldValue, _$isIdentityEqual)
                          }
                          yield &_name
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype attempts
                        var _$attempts: attempts {
                            get
                        }
                        associatedtype name
                        var _$name: name {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$attempts = Lattice._$placeholder(SessionState.self).attempts
                        let _$name = Lattice._$project(Lattice._$placeholder(SessionState.self).name)
                    }

                    @Lattice._IdentifiableIfPossible(SessionState.self)
                    @Lattice._EquatableIfPossible(SessionState.self)
                    struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: SessionState
                        init(_ state: SessionState) {
                            self._state = state
                        }
                        var name: _$ViewStateWitness.name {
                            Lattice._$project(_state.name)
                        }
                        @available(*, unavailable, message: "'token' is @Domain state and is not visible to views")
                        var token: String? {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'attempts' is @Domain state and is not visible to views")
                        var attempts: _$ViewStateWitness.attempts {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'createdAt' is @Domain state and is not visible to views")
                        var createdAt: Date {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'isExpired' is @Domain state and is not visible to views")
                        var isExpired: Bool {
                            fatalError()
                        }
                    }
                }

                extension SessionState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_IfConfig() {
            assertMacro {
                """
                @FeatureState
                struct DebugState {
                    var count = 0
                    #if DEBUG
                        var debugNote = "debug"
                        @Domain var debugSecret: Int = 0
                        @Domain var debugCounter = 0
                    #elseif TESTING
                        var testNote = "test"
                    #else
                        @Domain var releaseSecret: Int = 0
                    #endif
                    #if os(macOS)
                        private var macOnly = 0
                    #endif
                }
                """
            } expansion: {
                #"""
                struct DebugState {
                    var count {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.count)
                            return _count
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                          }
                          yield &_count
                        }
                    }
                    #if DEBUG
                        var debugNote = "debug"
                        var debugSecret: Int = 0
                        var debugCounter = 0
                    #elseif TESTING
                        var testNote = "test"
                    #else
                        var releaseSecret: Int = 0
                    #endif
                    #if os(macOS)
                        private var macOnly = 0
                    #endif

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype count
                        var _$count: count {
                            get
                        }
                        #if DEBUG
                        associatedtype debugNote
                        var _$debugNote: debugNote {
                            get
                        }
                        associatedtype debugCounter
                        var _$debugCounter: debugCounter {
                            get
                        }
                        #elseif TESTING
                        associatedtype testNote
                        var _$testNote: testNote {
                            get
                        }
                        #else
                        #endif
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$count = Lattice._$project(Lattice._$placeholder(DebugState.self).count)
                        #if DEBUG
                        let _$debugNote = Lattice._$project(Lattice._$placeholder(DebugState.self).debugNote)
                        let _$debugCounter = Lattice._$placeholder(DebugState.self).debugCounter
                        #elseif TESTING
                        let _$testNote = Lattice._$project(Lattice._$placeholder(DebugState.self).testNote)
                        #else
                        #endif
                    }

                    @Lattice._IdentifiableIfPossible(DebugState.self)
                    @Lattice._EquatableIfPossible(DebugState.self)
                    struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: DebugState
                        init(_ state: DebugState) {
                            self._state = state
                        }
                        var count: _$ViewStateWitness.count {
                            Lattice._$project(_state.count)
                        }
                        #if DEBUG
                        var debugNote: _$ViewStateWitness.debugNote {
                            Lattice._$project(_state.debugNote)
                        }
                        #elseif TESTING
                        var testNote: _$ViewStateWitness.testNote {
                            Lattice._$project(_state.testNote)
                        }
                        #else
                        #endif
                        #if DEBUG
                        @available(*, unavailable, message: "'debugSecret' is @Domain state and is not visible to views")
                        var debugSecret: Int {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'debugCounter' is @Domain state and is not visible to views")
                        var debugCounter: _$ViewStateWitness.debugCounter {
                            fatalError()
                        }
                        #elseif TESTING
                        #else
                        @available(*, unavailable, message: "'releaseSecret' is @Domain state and is not visible to views")
                        var releaseSecret: Int {
                            fatalError()
                        }
                        #endif
                    }
                }

                extension DebugState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_SendableFollowsInheritanceClause() {
            assertMacro {
                """
                @FeatureState
                struct UncheckedState: @unchecked Sendable {
                    var count = 0
                }
                """
            } expansion: {
                #"""
                struct UncheckedState: @unchecked Sendable {
                    var count {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.count)
                            return _count
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                          }
                          yield &_count
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype count
                        var _$count: count {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$count = Lattice._$project(Lattice._$placeholder(UncheckedState.self).count)
                    }

                    @Lattice._IdentifiableIfPossible(UncheckedState.self)
                    @Lattice._EquatableIfPossible(UncheckedState.self)
                    struct ViewState: Lattice.ViewStateProjection, Sendable {
                        @_spi(Lattice) public let _state: UncheckedState
                        init(_ state: UncheckedState) {
                            self._state = state
                        }
                        var count: _$ViewStateWitness.count {
                            Lattice._$project(_state.count)
                        }
                    }
                }

                extension UncheckedState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
            assertMacro {
                """
                @FeatureState
                struct ComposedState: Equatable & Swift.Sendable {
                    var count = 0
                }
                """
            } expansion: {
                #"""
                struct ComposedState: Equatable & Swift.Sendable {
                    var count {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.count)
                            return _count
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                          }
                          yield &_count
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype count
                        var _$count: count {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$count = Lattice._$project(Lattice._$placeholder(ComposedState.self).count)
                    }

                    @Lattice._IdentifiableIfPossible(ComposedState.self)
                    @Lattice._EquatableIfPossible(ComposedState.self)
                    struct ViewState: Lattice.ViewStateProjection, Sendable {
                        @_spi(Lattice) public let _state: ComposedState
                        init(_ state: ComposedState) {
                            self._state = state
                        }
                        var count: _$ViewStateWitness.count {
                            Lattice._$project(_state.count)
                        }
                    }
                }

                extension ComposedState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_FilePrivateState() {
            assertMacro {
                """
                @FeatureState
                private struct HiddenState: Equatable {
                    var count = 0
                    @Domain var secret = 1
                }
                """
            } expansion: {
                #"""
                private struct HiddenState: Equatable {
                    var count {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.count)
                            return _count
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                          }
                          yield &_count
                        }
                    }
                    var secret {
                        @storageRestrictions(initializes: _secret)
                        init(initialValue) {
                            _secret = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.secret)
                            return _secret
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.secret, &_secret, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.secret, &_secret)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.secret, &_secret, oldValue, _$isIdentityEqual)
                          }
                          yield &_secret
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    fileprivate protocol _$ViewStateTypes {
                        associatedtype count
                        var _$count: count {
                            get
                        }
                        associatedtype secret
                        var _$secret: secret {
                            get
                        }
                    }

                    fileprivate struct _$ViewStateWitness: _$ViewStateTypes {
                        fileprivate let _$count = Lattice._$project(Lattice._$placeholder(HiddenState.self).count)
                        fileprivate let _$secret = Lattice._$placeholder(HiddenState.self).secret
                    }

                    @Lattice._IdentifiableIfPossible(HiddenState.self)
                    @Lattice._EquatableIfPossible(HiddenState.self)
                    fileprivate struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: HiddenState
                        fileprivate init(_ state: HiddenState) {
                            self._state = state
                        }
                        fileprivate var count: _$ViewStateWitness.count {
                            Lattice._$project(_state.count)
                        }
                        @available(*, unavailable, message: "'secret' is @Domain state and is not visible to views")
                        fileprivate var secret: _$ViewStateWitness.secret {
                            fatalError()
                        }
                    }
                }

                extension HiddenState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Enum_EveryCaseKind() {
            assertMacro {
                """
                @CasePathable
                @FeatureState
                enum Phase: Equatable {
                    case loading
                    case loaded(LoadedState)
                    case failed(message: String, retryCount: Int)
                    var isBusy: Bool { if case .loading = self { true } else { false } }
                    @Domain var retryBudget: Int { 3 }
                }
                """
            } expansion: {
                """
                @CasePathable
                enum Phase: Equatable {
                    case loading
                    case loaded(LoadedState)
                    case failed(message: String, retryCount: Int)
                    var isBusy: Bool { if case .loading = self { true } else { false } }
                    var retryBudget: Int { 3 }

                    public var _$id: Lattice.ObservableStateID {
                        switch self {
                        case .loading:
                            return ObservableStateID._$inert._$tag(0)
                        case let .loaded(state):
                            return ._$id(for: state)._$tag(1)
                        case .failed:
                            return ObservableStateID._$inert._$tag(2)
                        }
                    }

                    public mutating func _$willModify() {
                        switch self {
                        case .loading:
                            break
                        case var .loaded(state):
                            Lattice._$willModify(&state)
                            self = .loaded(state)
                        case .failed:
                            break
                        }
                    }

                    protocol _$ViewStateTypes {
                        associatedtype loaded_0
                        var _$loaded_0: loaded_0 {
                            get
                        }
                        associatedtype failed_0
                        var _$failed_0: failed_0 {
                            get
                        }
                        associatedtype failed_1
                        var _$failed_1: failed_1 {
                            get
                        }
                        associatedtype isBusy
                        var _$isBusy: isBusy {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$loaded_0 = Lattice._$project(Lattice._$placeholder((LoadedState).self))
                        let _$failed_0 = Lattice._$project(Lattice._$placeholder((String).self))
                        let _$failed_1 = Lattice._$project(Lattice._$placeholder((Int).self))
                        let _$isBusy = Lattice._$project(Lattice._$placeholder(Phase.self).isBusy)
                    }

                    @Lattice._IdentifiableIfPossible(Phase.self)
                    @Lattice._EquatableIfPossible(Phase.self)
                    @CasePathable
                    enum ViewState: Lattice.ViewStateProjection {
                        case loading
                        case loaded(_$ViewStateWitness.loaded_0)
                        case failed(message: _$ViewStateWitness.failed_0, retryCount: _$ViewStateWitness.failed_1)
                        init(_ state: Phase) {
                            switch state {
                            case .loading:
                                self = .loading
                            case let .loaded(p0):
                                self = .loaded(Lattice._$project(p0))
                            case let .failed(p0, p1):
                                self = .failed(message: Lattice._$project(p0), retryCount: Lattice._$project(p1))
                            }
                        }
                        @_spi(Lattice) public var _state: Phase {
                            switch self {
                            case .loading:
                                return .loading
                            case let .loaded(p0):
                                return .loaded(Lattice._$unproject(p0, to: (LoadedState).self))
                            case let .failed(p0, p1):
                                return .failed(message: Lattice._$unproject(p0, to: (String).self), retryCount: Lattice._$unproject(p1, to: (Int).self))
                            }
                        }
                        var isBusy: _$ViewStateWitness.isBusy {
                            Lattice._$project(_state.isBusy)
                        }
                        @available(*, unavailable, message: "'retryBudget' is @Domain state and is not visible to views")
                        var retryBudget: Int {
                            fatalError()
                        }
                    }
                }

                extension Phase: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        func testViewState_Enum_IndirectAndPayloadSyntax() {
            assertMacro {
                """
                @FeatureState
                indirect enum Tree: Sendable {
                    case leaf(Int)
                    case node(Tree, Tree)
                }
                """
            } expansion: {
                """
                indirect enum Tree: Sendable {
                    case leaf(Int)
                    case node(Tree, Tree)

                    public var _$id: Lattice.ObservableStateID {
                        switch self {
                        case let .leaf(state):
                            return ._$id(for: state)._$tag(0)
                        case .node:
                            return ObservableStateID._$inert._$tag(1)
                        }
                    }

                    public mutating func _$willModify() {
                        switch self {
                        case var .leaf(state):
                            Lattice._$willModify(&state)
                            self = .leaf(state)
                        case .node:
                            break
                        }
                    }

                    protocol _$ViewStateTypes {
                        associatedtype leaf_0
                        var _$leaf_0: leaf_0 {
                            get
                        }
                        associatedtype node_0
                        var _$node_0: node_0 {
                            get
                        }
                        associatedtype node_1
                        var _$node_1: node_1 {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$leaf_0 = Lattice._$project(Lattice._$placeholder((Int).self))
                        let _$node_0 = Lattice._$project(Lattice._$placeholder((Tree).self))
                        let _$node_1 = Lattice._$project(Lattice._$placeholder((Tree).self))
                    }

                    @Lattice._IdentifiableIfPossible(Tree.self)
                    @Lattice._EquatableIfPossible(Tree.self)
                    indirect enum ViewState: Lattice.ViewStateProjection, Sendable {
                        case leaf(_$ViewStateWitness.leaf_0)
                        case node(_$ViewStateWitness.node_0, _$ViewStateWitness.node_1)
                        init(_ state: Tree) {
                            switch state {
                            case let .leaf(p0):
                                self = .leaf(Lattice._$project(p0))
                            case let .node(p0, p1):
                                self = .node(Lattice._$project(p0), Lattice._$project(p1))
                            }
                        }
                        @_spi(Lattice) public var _state: Tree {
                            switch self {
                            case let .leaf(p0):
                                return .leaf(Lattice._$unproject(p0, to: (Int).self))
                            case let .node(p0, p1):
                                return .node(Lattice._$unproject(p0, to: (Tree).self), Lattice._$unproject(p1, to: (Tree).self))
                            }
                        }
                    }
                }

                extension Tree: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
            assertMacro {
                """
                @CasePaths.CasePathable
                @FeatureState
                public enum Detail {
                    case none
                    case some(BadgeState?)
                    case rows([BadgeState])
                    case unlabeled(_ value: Int)
                    case mixed(Int, name: String)
                    indirect case nested(Detail)
                    #if DEBUG
                        case debug(String)
                    #endif
                }
                """
            } expansion: {
                """
                @CasePaths.CasePathable
                public enum Detail {
                    case none
                    case some(BadgeState?)
                    case rows([BadgeState])
                    case unlabeled(_ value: Int)
                    case mixed(Int, name: String)
                    indirect case nested(Detail)
                    #if DEBUG
                        case debug(String)
                    #endif

                    public var _$id: Lattice.ObservableStateID {
                        switch self {
                        case .none:
                            return ObservableStateID._$inert._$tag(0)
                        case let .some(state):
                            return ._$id(for: state)._$tag(1)
                        case let .rows(state):
                            return ._$id(for: state)._$tag(2)
                        case let .unlabeled(state):
                            return ._$id(for: state)._$tag(3)
                        case .mixed:
                            return ObservableStateID._$inert._$tag(4)
                        case let .nested(state):
                            return ._$id(for: state)._$tag(5)
                        #if DEBUG
                        case let .debug(state):
                            return ._$id(for: state)._$tag(6)
                        #endif

                        }
                    }

                    public mutating func _$willModify() {
                        switch self {
                        case .none:
                            break
                        case var .some(state):
                            Lattice._$willModify(&state)
                            self = .some(state)
                        case var .rows(state):
                            Lattice._$willModify(&state)
                            self = .rows(state)
                        case var .unlabeled(state):
                            Lattice._$willModify(&state)
                            self = .unlabeled(_ : state)
                        case .mixed:
                            break
                        case var .nested(state):
                            Lattice._$willModify(&state)
                            self = .nested(state)
                        #if DEBUG
                        case var .debug(state):
                            Lattice._$willModify(&state)
                            self = .debug(state)
                        #endif

                        }
                    }

                    public protocol _$ViewStateTypes {
                        associatedtype some_0
                        var _$some_0: some_0 {
                            get
                        }
                        associatedtype rows_0
                        var _$rows_0: rows_0 {
                            get
                        }
                        associatedtype unlabeled_0
                        var _$unlabeled_0: unlabeled_0 {
                            get
                        }
                        associatedtype mixed_0
                        var _$mixed_0: mixed_0 {
                            get
                        }
                        associatedtype mixed_1
                        var _$mixed_1: mixed_1 {
                            get
                        }
                        associatedtype nested_0
                        var _$nested_0: nested_0 {
                            get
                        }
                        #if DEBUG
                        associatedtype debug_0
                        var _$debug_0: debug_0 {
                            get
                        }
                        #endif
                    }

                    public struct _$ViewStateWitness: _$ViewStateTypes {
                        public let _$some_0 = Lattice._$project(Lattice._$placeholder((BadgeState?).self))
                        public let _$rows_0 = Lattice._$project(Lattice._$placeholder(([BadgeState]).self))
                        public let _$unlabeled_0 = Lattice._$project(Lattice._$placeholder((Int).self))
                        public let _$mixed_0 = Lattice._$project(Lattice._$placeholder((Int).self))
                        public let _$mixed_1 = Lattice._$project(Lattice._$placeholder((String).self))
                        public let _$nested_0 = Lattice._$project(Lattice._$placeholder((Detail).self))
                        #if DEBUG
                        public let _$debug_0 = Lattice._$project(Lattice._$placeholder((String).self))
                        #endif
                    }

                    @Lattice._IdentifiableIfPossible(Detail.self)
                    @Lattice._EquatableIfPossible(Detail.self)
                    @CasePaths.CasePathable
                    public enum ViewState: Lattice.ViewStateProjection {
                        case none
                        case some(_$ViewStateWitness.some_0)
                        case rows(_$ViewStateWitness.rows_0)
                        case unlabeled(_$ViewStateWitness.unlabeled_0)
                        case mixed(_$ViewStateWitness.mixed_0, name: _$ViewStateWitness.mixed_1)
                        indirect case nested(_$ViewStateWitness.nested_0)
                        #if DEBUG
                        case debug(_$ViewStateWitness.debug_0)
                        #endif
                        public init(_ state: Detail) {
                            switch state {
                            case .none:
                                self = .none
                            case let .some(p0):
                                self = .some(Lattice._$project(p0))
                            case let .rows(p0):
                                self = .rows(Lattice._$project(p0))
                            case let .unlabeled(p0):
                                self = .unlabeled(Lattice._$project(p0))
                            case let .mixed(p0, p1):
                                self = .mixed(Lattice._$project(p0), name: Lattice._$project(p1))
                            case let .nested(p0):
                                self = .nested(Lattice._$project(p0))
                            #if DEBUG
                            case let .debug(p0):
                                self = .debug(Lattice._$project(p0))
                            #endif
                            }
                        }
                        @_spi(Lattice) public var _state: Detail {
                            switch self {
                            case .none:
                                return .none
                            case let .some(p0):
                                return .some(Lattice._$unproject(p0, to: (BadgeState?).self))
                            case let .rows(p0):
                                return .rows(Lattice._$unproject(p0, to: ([BadgeState]).self))
                            case let .unlabeled(p0):
                                return .unlabeled(Lattice._$unproject(p0, to: (Int).self))
                            case let .mixed(p0, p1):
                                return .mixed(Lattice._$unproject(p0, to: (Int).self), name: Lattice._$unproject(p1, to: (String).self))
                            case let .nested(p0):
                                return .nested(Lattice._$unproject(p0, to: (Detail).self))
                            #if DEBUG
                            case let .debug(p0):
                                return .debug(Lattice._$unproject(p0, to: (String).self))
                            #endif
                            }
                        }
                    }
                }

                extension Detail: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        // MARK: - Diagnostics

        func testDiagnostic_GenericStruct() {
            assertMacro {
                """
                @FeatureState
                struct Box<Value> {
                    var value: Value
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct Box<Value> {
                          ┬──────
                          ├─ 🛑 '@FeatureState' cannot be applied to generic type 'Box': the generated projection uses a nested protocol, which Swift does not allow inside generic types (SE-0404). Make 'Box' non-generic or wrap the generic data in a non-generic state type.
                          ╰─ 🛑 '@FeatureState' cannot be applied to generic type 'Box': the generated projection uses a nested protocol, which Swift does not allow inside generic types (SE-0404). Make 'Box' non-generic or wrap the generic data in a non-generic state type.
                    var value: Value
                }
                """
            }
        }

        func testDiagnostic_GenericEnum() {
            assertMacro {
                """
                @FeatureState
                enum Loadable<Value> {
                    case idle
                    case loaded(Value)
                }
                """
            } diagnostics: {
                """
                @FeatureState
                enum Loadable<Value> {
                             ┬──────
                             ├─ 🛑 '@FeatureState' cannot be applied to generic type 'Loadable': the generated projection uses a nested protocol, which Swift does not allow inside generic types (SE-0404). Make 'Loadable' non-generic or wrap the generic data in a non-generic state type.
                             ╰─ 🛑 '@FeatureState' cannot be applied to generic type 'Loadable': the generated projection uses a nested protocol, which Swift does not allow inside generic types (SE-0404). Make 'Loadable' non-generic or wrap the generic data in a non-generic state type.
                    case idle
                    case loaded(Value)
                }
                """
            }
        }

        func testDiagnostic_DomainOnEnumCase() {
            assertMacro {
                """
                @FeatureState
                enum Phase {
                    @Domain case loading
                    case loaded(Int)
                }
                """
            } diagnostics: {
                """
                @FeatureState
                enum Phase {
                    @Domain case loading
                    ┬──────
                    ╰─ 🛑 '@Domain' can only be applied to instance properties
                    case loaded(Int)
                }
                """
            }
        }

        func testDiagnostic_DomainOnStaticMember() {
            assertMacro {
                """
                @FeatureState
                struct CounterState {
                    @Domain static var shared = 0
                    @Domain func reset() {}
                    var count = 0
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct CounterState {
                    @Domain static var shared = 0
                    ┬──────
                    ╰─ 🛑 '@Domain' can only be applied to instance properties
                    @Domain func reset() {}
                    ┬──────
                    ╰─ 🛑 '@Domain' can only be applied to instance properties
                    var count = 0
                }
                """
            }
        }

        func testDiagnostic_DomainIDOnIdentifiableState() {
            assertMacro {
                """
                @FeatureState
                struct RowState: Identifiable {
                    @Domain var id: Int
                    var title = ""
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct RowState: Identifiable {
                    @Domain var id: Int
                    ┬──────
                    ╰─ 🛑 'id' cannot be '@Domain' on an Identifiable state; its ViewState would not satisfy 'Identifiable'
                    var title = ""
                }
                """
            }
        }

        func testDiagnostic_ReservedNames() {
            assertMacro {
                """
                @FeatureState
                struct CounterState {
                    var count = 0
                    var _state = 0
                    struct ViewState {}
                    typealias _$ViewStateTypes = Int
                    enum _$ViewStateWitness {}
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct CounterState {
                    var count = 0
                    var _state = 0
                        ┬─────
                        ╰─ 🛑 '_state' is reserved by '@FeatureState'
                    struct ViewState {}
                           ┬────────
                           ╰─ 🛑 'ViewState' is reserved by '@FeatureState'
                    typealias _$ViewStateTypes = Int
                              ┬───────────────
                              ╰─ 🛑 '_$ViewStateTypes' is reserved by '@FeatureState'
                    enum _$ViewStateWitness {}
                         ┬─────────────────
                         ╰─ 🛑 '_$ViewStateWitness' is reserved by '@FeatureState'
                }
                """
            }
        }

        func testDiagnostic_ObservationIgnoredRenameFixIt() {
            assertMacro {
                """
                @FeatureState
                struct CounterState {
                    @ObservationIgnored var count = 0
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct CounterState {
                    @ObservationIgnored var count = 0
                    ┬──────────────────
                    ╰─ 🛑 '@ObservationIgnored' cannot be used in '@FeatureState'
                       ✏️ Use '@ObservationStateIgnored' instead
                }
                """
            } fixes: {
                """
                @FeatureState
                struct CounterState {
                    @ObservationStateIgnored var count = 0
                }
                """
            } expansion: {
                """
                struct CounterState {
                    var count = 0

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype count
                        var _$count: count {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$count = Lattice._$project(Lattice._$placeholder(CounterState.self).count)
                    }

                    @Lattice._IdentifiableIfPossible(CounterState.self)
                    @Lattice._EquatableIfPossible(CounterState.self)
                    struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: CounterState
                        init(_ state: CounterState) {
                            self._state = state
                        }
                        var count: _$ViewStateWitness.count {
                            Lattice._$project(_state.count)
                        }
                    }
                }

                extension CounterState: Lattice.FeatureState, Observation.Observable {
                }
                """
            }
        }

        // MARK: - Diagnostic recovery

        // `assertMacro` stops at error diagnostics, so these pin what is still generated: nothing
        // that would cascade into further compiler errors.

        private static let recoveryMacroSpecs: [String: MacroSpec] = [
            "FeatureState": MacroSpec(
                type: FeatureStateMacro.self,
                conformances: ["Lattice.FeatureState", "Observation.Observable"]
            ),
            "ObservationStateTracked": MacroSpec(type: ObservationStateTrackedMacro.self),
            "ObservationStateIgnored": MacroSpec(type: ObservationStateIgnoredMacro.self),
            "Domain": MacroSpec(type: DomainMacro.self),
        ]

        func testDiagnosticRecovery_GenericStateGeneratesNothing() {
            // The member and extension roles both report it; the memberAttribute role adds nothing.
            assertMacroExpansion(
                """
                @FeatureState
                struct Box<Value> {
                    var value: Value
                }
                """,
                expandedSource: """
                struct Box<Value> {
                    var value: Value
                }
                """,
                diagnostics: [
                    DiagnosticSpec(
                        message:
                            "'@FeatureState' cannot be applied to generic type 'Box': the generated projection uses a nested protocol, which Swift does not allow inside generic types (SE-0404). Make 'Box' non-generic or wrap the generic data in a non-generic state type.",
                        line: 2,
                        column: 11
                    ),
                    DiagnosticSpec(
                        message:
                            "'@FeatureState' cannot be applied to generic type 'Box': the generated projection uses a nested protocol, which Swift does not allow inside generic types (SE-0404). Make 'Box' non-generic or wrap the generic data in a non-generic state type.",
                        line: 2,
                        column: 11
                    )
                ],
                macroSpecs: Self.recoveryMacroSpecs
            )
        }

        func testDiagnosticRecovery_ReservedNameSkipsViewStateAndFeatureStateConformance() {
            assertMacroExpansion(
                """
                @FeatureState
                struct CounterState {
                    struct ViewState {}
                }
                """,
                expandedSource: """
                struct CounterState {
                    struct ViewState {}

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }
                }

                extension CounterState: Observation.Observable {
                }
                """,
                diagnostics: [
                    DiagnosticSpec(
                        message:
                            "'ViewState' is reserved by '@FeatureState'",
                        line: 3,
                        column: 12
                    )
                ],
                macroSpecs: Self.recoveryMacroSpecs
            )
        }

        func testDiagnosticRecovery_DomainIDSkipsUnavailableIDStub() {
            assertMacroExpansion(
                """
                @FeatureState
                struct RowState: Identifiable {
                    @Domain let id: Int
                }
                """,
                expandedSource: """
                struct RowState: Identifiable {
                    let id: Int

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                    }

                    @Lattice._IdentifiableIfPossible(RowState.self)
                    @Lattice._EquatableIfPossible(RowState.self)
                    struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: RowState
                        init(_ state: RowState) {
                            self._state = state
                        }
                    }
                }

                extension RowState: Lattice.FeatureState, Observation.Observable {
                }
                """,
                diagnostics: [
                    DiagnosticSpec(
                        message:
                            "'id' cannot be '@Domain' on an Identifiable state; its ViewState would not satisfy 'Identifiable'",
                        line: 3,
                        column: 5
                    )
                ],
                macroSpecs: Self.recoveryMacroSpecs
            )
        }
    }
#endif
