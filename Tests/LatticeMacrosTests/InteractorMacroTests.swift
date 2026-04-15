#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import XCTest

    final class InteractorMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(
                //                                record: .failed,
                macros: [InteractorMacro.self]
            ) {
                super.invokeTest()
            }
        }

        func testBasics_NoGenericsInMacro_EmitsError() {
            assertMacro {
                """
                @Interactor
                struct MyInteractor {
                    var body: some Interactor<Int, String> {
                        EmptyInteractor()
                    }
                }
                """
            } diagnostics: {
                """
                @Interactor
                 ┬─────────
                 ╰─ 🛑 @Interactor requires 2 generic arguments: one for the Interactor's state type and one for its action type.
                struct MyInteractor {
                    var body: some Interactor<Int, String> {
                        EmptyInteractor()
                    }
                }
                """
            }
        }

        func testBasics_GenericsInMacro() {
            assertMacro {
                """
                @Interactor<Int, String>
                struct MyInteractor {
                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }
                }
                """
            } expansion: {
                """
                struct MyInteractor {
                    @Lattice.InteractorBuilder<Int, String>
                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }

                    typealias DomainState = Int

                    typealias Action = String
                }

                extension MyInteractor: Lattice.Interactor {
                }
                """
            }
        }

        func testBasics_GenericsInMacro_OptionalState() {
            assertMacro {
                """
                @Interactor<Int?, String>
                struct MyInteractor {
                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }
                }
                """
            } expansion: {
                """
                struct MyInteractor {
                    @Lattice.InteractorBuilder<Int?, String>
                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }

                    typealias DomainState = Int?

                    typealias Action = String
                }

                extension MyInteractor: Lattice.Interactor {
                }
                """
            }
        }

        func testBasics_GenericsInMacro_ExistingTypealias_EmitsWarning() {
            assertMacro {
                """
                @Interactor<Int, String>
                struct MyInteractor {
                    typealias DomainState = Int
                    typealias Action = String

                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }
                }
                """
            } diagnostics: {
                """
                @Interactor<Int, String>
                struct MyInteractor {
                    typealias DomainState = Int
                    ┬──────────────────────────
                    ╰─ ⚠️ Consider removing explicit `typealias DomainState = Int`. This is handled by the `@Interactor` macro.
                    typealias Action = String
                    ┬────────────────────────
                    ╰─ ⚠️ Consider removing explicit `typealias Action = String`. This is handled by the `@Interactor` macro.

                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }
                }
                """
            } expansion: {
                """
                struct MyInteractor {
                    typealias DomainState = Int
                    typealias Action = String
                    @Lattice.InteractorBuilder<Int, String>

                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }
                }

                extension MyInteractor: Lattice.Interactor {
                }
                """
            }
        }

        func testMoreThanTwoGenericsInMacro() {
            assertMacro {
                """
                @Interactor<Int, String, Bool>
                struct MyInteractor {
                    var body: some Interactor<Int1, String> {
                        EmptyInteractor()
                    }
                }
                """
            } diagnostics: {
                """
                @Interactor<Int, String, Bool>
                 ┬────────────────────────────
                 ╰─ 🛑 @Interactor requires exactly 2 generic arguments: one for the Interactor's state type and one for its action type.
                struct MyInteractor {
                    var body: some Interactor<Int1, String> {
                        EmptyInteractor()
                    }
                }
                """
            }
        }
    }
#endif
