#if canImport(UnoArchitectureMacros)
    import UnoArchitectureMacros
    import MacroTesting
    import XCTest

    final class ViewModelMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(
                //                record: .failed,
                macros: [
                    ViewModelMacro.self,
                    SubscribeMacro.self,
                ]
            ) {
                super.invokeTest()
            }
        }

        func testBasics() {
            assertMacro {
                """
                @ViewModel<Int, String>
                final class MyViewModel {
                    init() {
                        self.viewState = "Hello, world!"
                    }
                }
                """
            } expansion: {
                """
                final class MyViewModel {
                    init() {
                        self.viewState = "Hello, world!"
                    }

                    @Published private(set) var viewState: Int

                    private let viewEvents = PassthroughSubject<String, Never>()

                    func sendViewEvent(_ event: String) {
                        viewEvents.send(event)
                    }
                }

                extension MyViewModel: UnoArchitecture.ViewModel {
                }
                """
            }
        }

        func testBasics_WithSubscribe() {
            assertMacro {
                """
                @ViewModel<Int, String>
                final class MyViewModel {
                    init(
                        interactor: AnyInteractor<String, Float>,
                        viewStateReducer: AnyViewStateReducer<Float, Int>
                    ) {
                        self.viewState = "Hello, world!"
                        #subscribe { builder in
                            builder
                                .viewStateReceiver(DispatchQueue.main)
                                .interactor(interactor)
                                .viewStateReducer(viewStateReducer)
                        }
                    }
                }
                """
            } expansion: {
                """
                final class MyViewModel {
                    init(
                        interactor: AnyInteractor<String, Float>,
                        viewStateReducer: AnyViewStateReducer<Float, Int>
                    ) {
                        self.viewState = "Hello, world!"
                        viewEvents
                            .interact(with: interactor)
                            .reduce(using: viewStateReducer)
                            .receive(on: DispatchQueue.main)
                            .assign(to: &$viewState)
                    }

                    @Published private(set) var viewState: Int

                    private let viewEvents = PassthroughSubject<String, Never>()

                    func sendViewEvent(_ event: String) {
                        viewEvents.send(event)
                    }
                }

                extension MyViewModel: UnoArchitecture.ViewModel {
                }
                """
            }
        }

        func testBasics_WithSubscribe_NoViewStateReducer() {
            assertMacro {
                """
                @ViewModel<Int, String>
                final class MyViewModel {
                    init(
                        interactor: AnyInteractor<Int, String>,
                    ) {
                        self.viewState = "Hello, world!"
                        #subscribe { builder in
                            builder
                                .viewStateReceiver(DispatchQueue.main)
                                .interactor(interactor)
                        }
                    }
                }
                """
            } expansion: {
                """
                final class MyViewModel {
                    init(
                        interactor: AnyInteractor<Int, String>,
                    ) {
                        self.viewState = "Hello, world!"
                        viewEvents
                            .interact(with: interactor)
                            .receive(on: DispatchQueue.main)
                            .assign(to: &$viewState)
                    }

                    @Published private(set) var viewState: Int

                    private let viewEvents = PassthroughSubject<String, Never>()

                    func sendViewEvent(_ event: String) {
                        viewEvents.send(event)
                    }
                }

                extension MyViewModel: UnoArchitecture.ViewModel {
                }
                """
            }
        }

        func testMoreThanTwoGenericsInMacro() {
            assertMacro {
                """
                @ViewModel<Int, String, Bool>
                final class MyViewModel {
                    init() {
                        self.viewState = "Hello, world!"
                    }
                }
                """
            } diagnostics: {
                """
                @ViewModel<Int, String, Bool>
                 ┬───────────────────────────
                 ╰─ 🛑 @ViewModel macro requires exactly 2 generic arguments: ViewStateType and ViewEventType
                final class MyViewModel {
                    init() {
                        self.viewState = "Hello, world!"
                    }
                }
                """
            }
        }
    }
#endif
