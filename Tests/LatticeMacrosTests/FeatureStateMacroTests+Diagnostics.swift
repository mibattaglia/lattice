#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import SwiftSyntaxMacroExpansion
    import SwiftSyntaxMacros
    import SwiftSyntaxMacrosTestSupport
    import XCTest

    extension FeatureStateMacroTests {
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
