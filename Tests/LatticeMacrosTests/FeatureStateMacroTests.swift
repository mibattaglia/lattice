#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import XCTest

    final class FeatureStateMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(macros: [FeatureStateMacro.self, FeatureStateTrackedMacro.self, DomainMacro.self]) {
                super.invokeTest()
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
                ╰─ 🛑 view-visible members need an explicit type annotation for generated member metadata
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
                ╰─ 🛑 '@FeatureState' generated-name collision with member metadata or tracked storage
                struct State {
                    var _viewMembers: Int = 0
                }
                """
            }
        }

        func testHiddenLazyInputIsNotSilentlyUntracked() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    @Domain lazy var hidden: Int = 0
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 lazy properties are unsupported by '@FeatureState', including hidden inputs
                struct State {
                    @Domain lazy var hidden: Int = 0
                }
                """
            }
        }

        func testHiddenWrapperIsNotSilentlyUntracked() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    @Wrapper private var hidden: Int = 0
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 property attributes/wrappers and member-specific availability are unsupported by '@FeatureState', including hidden stored inputs
                struct State {
                    @Wrapper private var hidden: Int = 0
                }
                """
            }
        }

        func testComputedSetterDiagnostic() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    var value: Int { get { 0 } set {} }
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 view-visible computed properties must have a synchronous, nonmutating, get-only getter
                struct State {
                    var value: Int { get { 0 } set {} }
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
