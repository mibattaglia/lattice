#if canImport(DomainArchitectureMacros)
    import DomainArchitectureMacros
    import MacroTesting
    import XCTest

    final class ViewStateReducerMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(
                record: .failed,
                macros: [ViewStateReducerMacro.self]
            ) {
                super.invokeTest()
            }
        }

        func testBasics_NoGenericsInMacro() {
            assertMacro {
                """
                @ViewStateReducer
                struct MyViewStateReducer {
                    var body: some ViewStateReducer<MyDomainState, MyViewState> {
                        BuildViewState<MyDomainState, MyViewState> { .none }
                    }
                }
                """
            } expansion: {
                """
                struct MyViewStateReducer {
                    @DomainArchitecture.ViewStateReducerBuilder<MyDomainState, MyViewState>
                    var body: some ViewStateReducer<MyDomainState, MyViewState> {
                        BuildViewState<MyDomainState, MyViewState> { .none }
                    }
                }

                extension MyViewStateReducer: DomainArchitecture.ViewStateReducer {
                }
                """
            }
        }

        func testBasics_NoGenericsInMacro_NestedStateAndAction() {
            assertMacro {
                """
                @ViewStateReducer
                struct MyViewStateReducer {
                    enum DomainState {}
                    enum ViewState {}
                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState<DomainState, ViewState> { .none }
                    }
                }
                """
            } expansion: {
                """
                struct MyViewStateReducer {
                    enum DomainState {}
                    enum ViewState {}
                    @DomainArchitecture.ViewStateReducerBuilder<Self.DomainState, Self.ViewState>
                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState<DomainState, ViewState> { .none }
                    }
                }

                extension MyViewStateReducer: DomainArchitecture.ViewStateReducer {
                }
                """
            }
        }

        func testBasics_GenericsInMacro() {
            assertMacro {
                """
                @ViewStateReducer<Int, String>
                struct MyViewStateReducer {
                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }
                }
                """
            } expansion: {
                """
                struct MyViewStateReducer {
                    @DomainArchitecture.ViewStateReducerBuilder<Int, String>
                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }

                    typealias DomainState = Int

                    typealias ViewState = String
                }

                extension MyViewStateReducer: DomainArchitecture.ViewStateReducer {
                }
                """
            }
        }

        func testBasics_GenericsInMacro_ExistingTypealias_EmitsWarning() {
            assertMacro {
                """
                @ViewStateReducer<Int, String>
                struct MyViewStateReducer {
                    typealias DomainState = Int
                    typealias ViewState = String

                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }
                }
                """
            } diagnostics: {
                """
                @ViewStateReducer<Int, String>
                struct MyViewStateReducer {
                    typealias DomainState = Int
                    ┬──────────────────────────
                    ╰─ ⚠️ Consider removing explicit `typealias DomainState = Int`. This is handled by the `@ViewStateReducer` macro.
                    typealias ViewState = String
                    ┬───────────────────────────
                    ╰─ ⚠️ Consider removing explicit `typealias ViewState = String`. This is handled by the `@ViewStateReducer` macro.

                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }
                }
                """
            } expansion: {
                """
                struct MyViewStateReducer {
                    typealias DomainState = Int
                    typealias ViewState = String
                    @DomainArchitecture.ViewStateReducerBuilder<Int, String>

                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }
                }

                extension MyViewStateReducer: DomainArchitecture.ViewStateReducer {
                }
                """
            }
        }

        func testGenericsInMacro_EmitsError() {
            assertMacro {
                """
                @ViewStateReducer<Int, String>
                struct MyViewStateReducer {
                    var body: some ViewStateReducer<Int1, String> {
                        BuildViewState { .none }
                    }
                }
                """
            } diagnostics: {
                """
                @ViewStateReducer<Int, String>
                struct MyViewStateReducer {
                    var body: some ViewStateReducer<Int1, String> {
                        ┬───
                        ╰─ 🛑 Generic parameters have already been applied to the attached macro and will take precedence over those specified in `body`
                           ✏️ Replace 'some ViewStateReducer<Int1, String>' with 'some ViewStateReducerOf<Self>'
                        BuildViewState { .none }
                    }
                }
                """
            } fixes: {
                """
                @ViewStateReducer<Int, String>
                struct MyViewStateReducer {
                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }
                }
                """
            } expansion: {
                """
                struct MyViewStateReducer {
                    @DomainArchitecture.ViewStateReducerBuilder<Int, String>
                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }

                    typealias DomainState = Int

                    typealias ViewState = String
                }

                extension MyViewStateReducer: DomainArchitecture.ViewStateReducer {
                }
                """
            }
        }

        func testMoreThanTwoGenericsInMacro() {
            assertMacro {
                """
                @ViewStateReducer<Int, String, Bool>
                struct MyViewStateReducer {
                    var body: some ViewStateReducer<Int1, String> {
                        BuildViewState { .none }
                    }
                }
                """
            } diagnostics: {
                """
                @ViewStateReducer<Int, String, Bool>
                 ┬──────────────────────────────────
                 ╰─ 🛑 Only 2 generic arguments should be applied the @ViewStateReducer macro. One for the ViewStateReducer's domain state type and one for its view state type. 
                struct MyViewStateReducer {
                    var body: some ViewStateReducer<Int1, String> {
                        BuildViewState { .none }
                    }
                }
                """
            }
        }
    }
#endif
