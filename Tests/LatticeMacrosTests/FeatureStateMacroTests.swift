#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import XCTest

    final class FeatureStateMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(macros: [FeatureStateMacro.self, DomainMacro.self]) {
                super.invokeTest()
            }
        }

        func testGenericDescriptorsPreserveGetterAccess() {
            assertMacro {
                """
                @FeatureState
                public struct State<Value: Equatable> {
                    public var value: Value
                    public var child: Child
                    var moduleOnly: String
                    package var packageOnly: Int
                    public private(set) var readOnly: Int
                    @Domain public var secret: Int
                    private var privateValue: Int
                    fileprivate var fileValue: Int
                    static var shared: Int = 0
                }
                """
            } expansion: {
                """
                public struct State<Value: Equatable> {
                    public var value: Value
                    public var child: Child
                    var moduleOnly: String
                    package var packageOnly: Int
                    public private(set) var readOnly: Int
                    public var secret: Int
                    private var privateValue: Int
                    fileprivate var fileValue: Int
                    static var shared: Int = 0

                    public struct _ViewMembers {
                        public let value = Lattice._projectionMember(\\State<Value>.value)
                        public let child = Lattice._projectionMember(\\State<Value>.child)
                        let moduleOnly = Lattice._projectionMember(\\State<Value>.moduleOnly)
                        package let packageOnly = Lattice._projectionMember(\\State<Value>.packageOnly)
                        public let readOnly = Lattice._projectionMember(\\State<Value>.readOnly)
                    }

                    @MainActor
                    public static var _viewMembers: _ViewMembers {
                        _ViewMembers()
                    }

                    @MainActor
                    public static func _commit(old: Self, new: Self, registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey) {
                        Lattice._commitProjectionMember(_viewMembers.value, old: old, new: new, registrar: registrar, key: key.appending(\\_ViewMembers.value))
                        Lattice._commitProjectionMember(_viewMembers.child, old: old, new: new, registrar: registrar, key: key.appending(\\_ViewMembers.child))
                        Lattice._commitProjectionMember(_viewMembers.moduleOnly, old: old, new: new, registrar: registrar, key: key.appending(\\_ViewMembers.moduleOnly))
                        Lattice._commitProjectionMember(_viewMembers.packageOnly, old: old, new: new, registrar: registrar, key: key.appending(\\_ViewMembers.packageOnly))
                        Lattice._commitProjectionMember(_viewMembers.readOnly, old: old, new: new, registrar: registrar, key: key.appending(\\_ViewMembers.readOnly))
                    }
                }
                """
            }
        }
        func testMissingTypeDiagnostic() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    var value = 1
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 view-visible members need an explicit type annotation for the generated projection
                struct State {
                    var value = 1
                }
                """
            }
        }

        func testClassDiagnostic() {
            assertMacro {
                """
                @FeatureState
                class State {}
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 '@FeatureState' can only be attached to structs and enums
                class State {}
                """
            }
        }

        func testGeneratedNameCollisionDiagnostic() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    var _viewMembers: Int = 0
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 '@FeatureState' generated-name collision with _ViewMembers, _viewMembers, or _commit
                struct State {
                    var _viewMembers: Int = 0
                }
                """
            }
        }
        func testDerivedDescriptorAndStoredObserver() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    @Domain var input: Int = 0
                    var stored: Int = 0 { didSet {} }
                    var label: String { "\\(input)" }
                }
                """
            } expansion: {
                """
                struct State {
                    var input: Int = 0
                    var stored: Int = 0 { didSet {} }
                    var label: String { "\\(input)" }

                    struct _ViewMembers {
                        let stored = Lattice._projectionMember(\\State.stored)
                        let label = Lattice._derivedProjectionMember(\\State.label)
                    }

                    @MainActor
                    static var _viewMembers: _ViewMembers {
                        _ViewMembers()
                    }

                    @MainActor
                    static func _commit(old: Self, new: Self, registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey) {
                        Lattice._commitProjectionMember(_viewMembers.stored, old: old, new: new, registrar: registrar, key: key.appending(\\_ViewMembers.stored))
                        Lattice._commitProjectionMember(_viewMembers.label, old: old, new: new, registrar: registrar, key: key.appending(\\_ViewMembers.label))
                    }
                }
                """
            }
        }

        func testEnumCaseDescriptors() {
            assertMacro {
                """
                @FeatureState
                enum Phase {
                    case idle
                    case ready(Child)
                }
                """
            } expansion: {
                """
                enum Phase {
                    case idle
                    case ready(Child)

                    var ready: Child? {
                        guard case .ready(let value) = self else {
                            return nil
                        }
                        return value
                    }

                    struct _ViewMembers {
                        let ready = Lattice._projectionMember(\\Phase.ready)
                    }

                    @MainActor
                    static var _viewMembers: _ViewMembers {
                        _ViewMembers()
                    }

                    @MainActor
                    static func _commit(old: Self, new: Self, registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey) {
                        switch (old, new) {
                        case (.idle, .idle):
                            break
                        case (.ready, .ready):
                            break
                        default:
                            Lattice._invalidateProjectionSubtree(registrar: registrar, key: key)
                        }
                        Lattice._commitProjectionMember(_viewMembers.ready, old: old, new: new, registrar: registrar, key: key.appending(\\_ViewMembers.ready))
                    }
                }
                """
            }
        }
        func testDomainOutsideStateDiagnostic() {
            assertMacro {
                """
                @Domain var value: Int = 0
                """
            } diagnostics: {
                """
                @Domain var value: Int = 0
                ┬──────
                ╰─ 🛑 '@Domain' requires an instance property in an '@FeatureState' declaration
                """
            }
        }
    }
#endif
