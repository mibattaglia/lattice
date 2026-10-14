#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import SwiftSyntaxMacroExpansion
    import SwiftSyntaxMacros
    import SwiftSyntaxMacrosTestSupport
    import XCTest

    extension FeatureStateMacroTests {
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
    }
#endif
