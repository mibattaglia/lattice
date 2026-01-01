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

                    private var viewEventContinuation: AsyncStream<String>.Continuation?

                    private var subscriptionTask: Task<Void, Never>?

                    func sendViewEvent(_ event: String) {
                        viewEventContinuation?.yield(event)
                    }

                    deinit {
                        viewEventContinuation?.finish()
                        subscriptionTask?.cancel()
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
                        ({
                            let interactor = interactor
                            let viewStateReducer = viewStateReducer
                            let (stream, continuation) = AsyncStream.makeStream(of: ViewEventType.self)
                            self.viewEventContinuation = continuation
                            self.subscriptionTask = Task { [interactor, viewStateReducer, stream] in
                                for await domainState in interactor.interact(stream) {
                                    guard !Task.isCancelled else {
                                            break
                                        }
                                    await MainActor.run { [weak self] in
                                        self?.viewState = viewStateReducer.reduce(domainState)
                                    }
                                }
                            }
                            })()
                    }

                    @Published private(set) var viewState: Int

                    private var viewEventContinuation: AsyncStream<String>.Continuation?

                    private var subscriptionTask: Task<Void, Never>?

                    func sendViewEvent(_ event: String) {
                        viewEventContinuation?.yield(event)
                    }

                    deinit {
                        viewEventContinuation?.finish()
                        subscriptionTask?.cancel()
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
                        ({
                            let interactor = interactor
                            let (stream, continuation) = AsyncStream.makeStream(of: ViewEventType.self)
                            self.viewEventContinuation = continuation
                            self.subscriptionTask = Task { [interactor, stream] in
                                for await domainState in interactor.interact(stream) {
                                    guard !Task.isCancelled else {
                                            break
                                        }
                                    await MainActor.run { [weak self] in
                                        self?.viewState = domainState
                                    }
                                }
                            }
                            })()
                    }

                    @Published private(set) var viewState: Int

                    private var viewEventContinuation: AsyncStream<String>.Continuation?

                    private var subscriptionTask: Task<Void, Never>?

                    func sendViewEvent(_ event: String) {
                        viewEventContinuation?.yield(event)
                    }

                    deinit {
                        viewEventContinuation?.finish()
                        subscriptionTask?.cancel()
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
