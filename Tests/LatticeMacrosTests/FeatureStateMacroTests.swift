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

    }
#endif
