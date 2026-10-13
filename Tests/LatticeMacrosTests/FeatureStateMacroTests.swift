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

        func testKnownSupportedPropertyWrappers() {
            assertMacro {
                """
                @FeatureState
                struct State {
                  @Shared var shared: Int
                  @SharedReader var sharedReader: Int
                  @Fetch var fetch: Int 
                  @FetchAll var fetchAll: Int 
                  @FetchOne var fetchOne: Int
                }
                """
            } expansion: {
                """
                struct State {
                  @Shared
                  var shared: Int
                  @SharedReader
                  var sharedReader: Int
                  @Fetch
                  var fetch: Int 
                  @FetchAll
                  var fetchAll: Int 
                  @FetchOne
                  var fetchOne: Int

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
                    associatedtype shared
                    var _$shared: shared {
                      get
                    }
                    associatedtype sharedReader
                    var _$sharedReader: sharedReader {
                      get
                    }
                    associatedtype fetch
                    var _$fetch: fetch {
                      get
                    }
                    associatedtype fetchAll
                    var _$fetchAll: fetchAll {
                      get
                    }
                    associatedtype fetchOne
                    var _$fetchOne: fetchOne {
                      get
                    }
                  }

                  struct _$ViewStateWitness: _$ViewStateTypes {
                    let _$shared = Lattice._$project(Lattice._$placeholder(State.self).shared)
                    let _$sharedReader = Lattice._$project(Lattice._$placeholder(State.self).sharedReader)
                    let _$fetch = Lattice._$project(Lattice._$placeholder(State.self).fetch)
                    let _$fetchAll = Lattice._$project(Lattice._$placeholder(State.self).fetchAll)
                    let _$fetchOne = Lattice._$project(Lattice._$placeholder(State.self).fetchOne)
                  }

                  @Lattice._IdentifiableIfPossible(State.self)
                  @Lattice._EquatableIfPossible(State.self)
                  struct ViewState: Lattice.ViewStateProjection {
                    @_spi(Lattice) public let _state: State
                    init(_ state: State) {
                      self._state = state
                    }
                    var shared: _$ViewStateWitness.shared {
                      Lattice._$project(_state.shared)
                    }
                    var sharedReader: _$ViewStateWitness.sharedReader {
                      Lattice._$project(_state.sharedReader)
                    }
                    var fetch: _$ViewStateWitness.fetch {
                      Lattice._$project(_state.fetch)
                    }
                    var fetchAll: _$ViewStateWitness.fetchAll {
                      Lattice._$project(_state.fetchAll)
                    }
                    var fetchOne: _$ViewStateWitness.fetchOne {
                      Lattice._$project(_state.fetchOne)
                    }
                  }
                }

                extension State: Lattice.FeatureState, Observation.Observable {
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
