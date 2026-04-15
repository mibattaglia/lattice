#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import XCTest

    final class ViewStateReducerMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(
                //                record: .failed,
                macros: [ViewStateReducerMacro.self]
            ) {
                super.invokeTest()
            }
        }

        func testBasics_NoGenericsInMacro_EmitsError() {
            assertMacro {
                """
                @ViewStateReducer
                struct MyViewStateReducer {
                    var body: some ViewStateReducer<MyDomainState, MyViewState> {
                        BuildViewState<MyDomainState, MyViewState> { .none }
                    }
                }
                """
            } diagnostics: {
                """
                @ViewStateReducer
                 ┬───────────────
                 ╰─ 🛑 @ViewStateReducer requires 2 generic arguments: one for the ViewStateReducer's domain state type and one for its view state type.
                struct MyViewStateReducer {
                    var body: some ViewStateReducer<MyDomainState, MyViewState> {
                        BuildViewState<MyDomainState, MyViewState> { .none }
                    }
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
                    @Lattice.ViewStateReducerBuilder<Int, String>
                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }

                    typealias DomainState = Int

                    typealias ViewState = String

                    func initialViewState(for _: DomainState) -> ViewState {
                        .defaultValue
                    }
                }

                extension MyViewStateReducer: Lattice.ViewStateReducer {
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
                    @Lattice.ViewStateReducerBuilder<Int, String>

                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }

                    func initialViewState(for _: DomainState) -> ViewState {
                        .defaultValue
                    }
                }

                extension MyViewStateReducer: Lattice.ViewStateReducer {
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
                 ╰─ 🛑 @ViewStateReducer requires exactly 2 generic arguments: one for the ViewStateReducer's domain state type and one for its view state type.
                struct MyViewStateReducer {
                    var body: some ViewStateReducer<Int1, String> {
                        BuildViewState { .none }
                    }
                }
                """
            }
        }

        func testMissingInitialViewStateWithLocalNonDefaultViewStateEmitsError() {
            assertMacro {
                """
                @ViewStateReducer<Int, ViewState>
                struct MyViewStateReducer {
                    struct ViewState {}

                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }
                }
                """
            } diagnostics: {
                """
                @ViewStateReducer<Int, ViewState>
                ╰─ 🛑 Missing `initialViewState(for:)` on this `@ViewStateReducer`. Add an explicit implementation or conform ViewState to DefaultValueProvider.
                struct MyViewStateReducer {
                    struct ViewState {}

                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }
                }
                """
            }
        }

        func testLocalNonDefaultViewStateWithExplicitInitialViewStateDoesNotSynthesizeDuplicate() {
            assertMacro {
                """
                @ViewStateReducer<Int, ViewState>
                struct MyViewStateReducer {
                    struct ViewState {}

                    func initialViewState(for _: DomainState) -> ViewState {
                        .init()
                    }

                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }
                }
                """
            } expansion: {
                """
                struct MyViewStateReducer {
                    struct ViewState {}

                    func initialViewState(for _: DomainState) -> ViewState {
                        .init()
                    }
                    @Lattice.ViewStateReducerBuilder<Int, ViewState>

                    var body: some ViewStateReducerOf<Self> {
                        BuildViewState { .none }
                    }

                    typealias DomainState = Int

                    typealias ViewState = ViewState
                }

                extension MyViewStateReducer: Lattice.ViewStateReducer {
                }
                """
            }
        }
    }
#endif
