#if canImport(UnoArchitectureMacros)
    import UnoArchitectureMacros
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

        func testBasics_NoGenericsInMacro() {
            assertMacro {
                """
                @Interactor
                struct MyInteractor {
                    var body: some Interactor<Int, String> {
                        EmptyInteractor()
                    }
                }
                """
            } expansion: {
                """
                struct MyInteractor {
                    @UnoArchitecture.InteractorBuilder<Int, String>
                    var body: some Interactor<Int, String> {
                        EmptyInteractor()
                    }
                }

                extension MyInteractor: UnoArchitecture.Interactor {
                }
                """
            }
        }

        func testBasics_NoGenericsInMacro_NestedStateAndAction() {
            assertMacro {
                """
                @Interactor
                struct MyInteractor {
                    struct DomainState {}
                    enum Action {}
                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }
                }
                """
            } expansion: {
                """
                struct MyInteractor {
                    struct DomainState {}
                    enum Action {}
                    @UnoArchitecture.InteractorBuilder<Self.State, Self.Action>
                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }
                }

                extension MyInteractor: UnoArchitecture.Interactor {
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
                    @UnoArchitecture.InteractorBuilder<Int, String>
                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }

                    typealias DomainState = Int

                    typealias Action = String
                }

                extension MyInteractor: UnoArchitecture.Interactor {
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
                    @UnoArchitecture.InteractorBuilder<Int?, String>
                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }
                
                    typealias DomainState = Int?
                
                    typealias Action = String
                }
                
                extension MyInteractor: UnoArchitecture.Interactor {
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
                    @UnoArchitecture.InteractorBuilder<Int, String>

                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }
                }

                extension MyInteractor: UnoArchitecture.Interactor {
                }
                """
            }
        }

        func testGenericsInMacro_EmitsError() {
            assertMacro {
                """
                @Interactor<Int, String>
                struct MyInteractor {
                    var body: some Interactor<Int1, String> {
                        EmptyInteractor()
                    }
                }
                """
            } diagnostics: {
                """
                @Interactor<Int, String>
                struct MyInteractor {
                    var body: some Interactor<Int1, String> {
                        ┬───
                        ╰─ 🛑 Generic parameters have already been applied to the attached macro and will take precedence over those specified in `body`
                           ✏️ Replace 'some Interactor<Int1, String>' with 'some InteractorOf<Self>'
                        EmptyInteractor()
                    }
                }
                """
            } fixes: {
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
                    @UnoArchitecture.InteractorBuilder<Int, String>
                    var body: some InteractorOf<Self> {
                        EmptyInteractor()
                    }

                    typealias DomainState = Int

                    typealias Action = String
                }

                extension MyInteractor: UnoArchitecture.Interactor {
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
                 ╰─ 🛑 Only 2 generic arguments should be applied the @Interactor macro. One for the Interactor's state type and one for its action type. 
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
