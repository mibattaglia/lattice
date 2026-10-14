#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import SwiftSyntaxMacroExpansion
    import SwiftSyntaxMacros
    import SwiftSyntaxMacrosTestSupport
    import XCTest

    extension FeatureStateMacroTests {
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
    }
#endif
