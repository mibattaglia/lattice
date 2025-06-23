#if canImport(UnoArchitectureMacros)
    import UnoArchitectureMacros
    import MacroTesting
    import XCTest

    final class ViewModelMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(
                record: .failed,
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
                        interactor: AnyInteractor<Bool, Float>,
                        viewStateReducer: AnyViewStateReducer<Float, String>
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
                        interactor: AnyInteractor<Bool, Float>,
                        viewStateReducer: AnyViewStateReducer<Float, String>
                    ) {
                        self.viewState = "Hello, world!"
                        {
                            var __uno_builder = ViewModelBuilder()
                            __uno_builder.interactor(interactor)
                                __uno_builder.viewStateReceiver(DispatchQueue.main)
                                __uno_builder.viewStateReducer(viewStateReducer)
                            let __uno_config = try! __uno_builder.build()
                            viewEvents
                                    .interact(with: __uno_config.interactor)
                                    .reduce(using: __uno_config.viewStateReducer!)
                                    .receive(on: __uno_config.viewStateReceiver)
                                    .assign(to: &$viewState)
                        }()
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

        func testBasics_WithSimpleSubscribe() {
            assertMacro {
                """
                @ViewModel<Int, String>
                final class MyViewModel {
                    init(
                        interactor: AnyInteractor<Bool, String>
                    ) {
                        self.viewState = "Hello, world!"
                        #subscribeSimple(DispatchQueue.main, interactor)
                    }
                }
                """
            } expansion: {
                """
                final class MyViewModel {
                    init(
                        interactor: AnyInteractor<Bool, String>
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
