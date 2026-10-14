#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import SwiftSyntaxMacroExpansion
    import XCTest

    final class FeatureStateSupportMacrosTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(
                macros: [
                    "Domain": MacroSpec(type: DomainMacro.self),
                    // The constrained overloads: the compiler only selects them when the state
                    // has the conformance, so the `MacroSpec`s report it as missing.
                    "_IdentifiableIfPossible": MacroSpec(
                        type: IdentifiableIfPossibleMacro.self,
                        conformances: ["Identifiable"]
                    ),
                    "_EquatableIfPossible": MacroSpec(
                        type: EquatableIfPossibleMacro.self,
                        conformances: ["Equatable"]
                    ),
                ]
            ) {
                super.invokeTest()
            }
        }

        func testDomain_ExpandsToNothing() {
            assertMacro {
                """
                struct CounterState {
                    @Domain var lastUpdatedAt: Date?
                }
                """
            } expansion: {
                """
                struct CounterState {
                    var lastUpdatedAt: Date?
                }
                """
            }
        }

        func testIdentifiableIfPossible_AddsConformanceOnly() {
            assertMacro {
                """
                @_IdentifiableIfPossible(RowState.self)
                struct ViewState {
                }
                """
            } expansion: {
                """
                struct ViewState {
                }

                extension ViewState: Identifiable {
                }
                """
            }
        }

        func testEquatableIfPossible_ComparesState() {
            assertMacro {
                """
                @_EquatableIfPossible(CounterState.self)
                struct ViewState {
                }
                """
            } expansion: {
                """
                struct ViewState {
                }

                extension ViewState: Equatable {
                    static func == (lhs: Self, rhs: Self) -> Bool {
                        lhs._state == rhs._state
                    }
                }
                """
            }
        }

        func testEquatableIfPossible_MirrorsProjectionAccess() {
            assertMacro {
                """
                @_EquatableIfPossible(CounterState.self)
                public struct ViewState {
                }
                """
            } expansion: {
                """
                public struct ViewState {
                }

                extension ViewState: Equatable {
                    public static func == (lhs: Self, rhs: Self) -> Bool {
                        lhs._state == rhs._state
                    }
                }
                """
            }
            assertMacro {
                """
                @_EquatableIfPossible(CounterState.self)
                package enum ViewState {
                }
                """
            } expansion: {
                """
                package enum ViewState {
                }

                extension ViewState: Equatable {
                    package static func == (lhs: Self, rhs: Self) -> Bool {
                        lhs._state == rhs._state
                    }
                }
                """
            }
            assertMacro {
                """
                @_EquatableIfPossible(HiddenState.self)
                fileprivate struct ViewState {
                }
                """
            } expansion: {
                """
                fileprivate struct ViewState {
                }

                extension ViewState: Equatable {
                    fileprivate static func == (lhs: Self, rhs: Self) -> Bool {
                        lhs._state == rhs._state
                    }
                }
                """
            }
        }

        func testConformanceMacros_CopyAvailability() {
            assertMacro {
                """
                @available(iOS 18, *)
                @_IdentifiableIfPossible(RowState.self)
                @_EquatableIfPossible(RowState.self)
                struct ViewState {
                }
                """
            } expansion: {
                """
                @available(iOS 18, *)
                struct ViewState {
                }

                @available(iOS 18, *) extension ViewState: Identifiable {
                }

                @available(iOS 18, *) extension ViewState: Equatable {
                    static func == (lhs: Self, rhs: Self) -> Bool {
                        lhs._state == rhs._state
                    }
                }
                """
            }
        }

        func testNoOpExtension_UnconstrainedOverloadAddsNothing() {
            assertMacro(
                ["_EquatableIfPossible": MacroSpec(type: NoOpExtensionMacro.self, conformances: ["Equatable"])]
            ) {
                """
                @_EquatableIfPossible(CounterState.self)
                struct ViewState {
                }
                """
            } expansion: {
                """
                struct ViewState {
                }
                """
            }
        }
    }
#endif
