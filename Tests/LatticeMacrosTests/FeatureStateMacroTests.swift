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
    }
#endif
