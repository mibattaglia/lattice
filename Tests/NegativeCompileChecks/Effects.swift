// Concurrency fixtures for scripts/negative-compile-checks.sh. Compiled with `-emit-sil -wmo`, together
// with the other files in this directory, because region-isolation diagnostics are produced only
// by SIL passes, never by `-typecheck`. This module stands in for a consumer: it does not enable
// `NonisolatedNonsendingByDefault`.

import Lattice
import Observation

#if NO_SENDABLE_BASELINE
    // Positive check (`-warnings-as-errors`): non-Sendable state, action and dependency compile
    // without a single `Sendable` annotation. The dependency's async method is
    // `nonisolated(nonsending)`, so the effect calls it on the model's isolation.

    final class NonSendableBox {
        var value = 0
    }

    final class NonSendableClient {
        var calls = 0

        nonisolated(nonsending) func fetch() async throws -> NonSendableBox {
            calls += 1
            return NonSendableBox()
        }
    }

    @FeatureState
    struct NonSendableState {
        var count = 0
        var box = NonSendableBox()
        var isLoading = false
    }

    enum NonSendableAction {
        case load
        case received(NonSendableBox)
    }

    @Interactor<NonSendableState, NonSendableAction>
    struct NonSendableInteractor {
        @EffectID var load
        let client: NonSendableClient

        var body: some InteractorOf<Self> {
            Interact { state, action, effects in
                switch action {
                case .load:
                    state.isLoading = true
                    effects.perform(id: load) {
                        defer { try? effects.modify { $0.isLoading = false } }
                        let box = try await client.fetch()
                        try effects.modify {
                            $0.count = box.value
                            $0.box = box
                        }
                        try effects.send(.received(box))
                    }
                case .received(let box):
                    state.box = box
                }
            }
        }
    }

    @MainActor
    func runNonSendableFeature() async {
        let viewModel = ViewModel(
            initialState: NonSendableState(),
            feature: Feature(interactor: NonSendableInteractor(client: NonSendableClient()))
        )
        await viewModel.sendViewEvent(.load)?.value
        viewModel.sendViewEvent(.received(NonSendableBox()))
        _ = viewModel.count
    }
#endif

#if PERFORM_IN_EFFECT
    // `perform` is legal only while `interact` runs; inside an effect it is a compile error.
    @Interactor<CounterState, CounterAction>
    struct PerformInEffectInteractor {
        var body: some InteractorOf<Self> {
            Interact { _, _, effects in
                effects.perform {
                    effects.perform {}
                }
            }
        }
    }
#endif

#if MAINACTOR_INTERACTOR_TO_TESTMODEL
    // An interactor formed in main-actor-isolated code is a main-actor value, and so is the
    // `Feature` built from it: region isolation rejects sending it to the `TestModel` actor. A
    // `@MainActor` test cannot pass `TestModel.receive` its predicate either. Such features use
    // `TestViewModel`. The diagnostics name the `Feature` value, which is what `TestModel.init`
    // takes.

    @MainActor
    func makeMainActorTitleInteractor() -> Interact<CounterState, CounterAction> {
        Interact { state, action, effects in
            if case .titleChanged(let title) = action {
                state.title = title
                effects.perform {
                    await Task.yield()
                    try effects.send(.lastUpdatedAtChanged(nil))
                }
            }
        }
    }

    /// A nonisolated test that gets its interactor from a `@MainActor` factory.
    @available(iOS 26, macOS 26, watchOS 26, *)
    func runMainActorFactoryInteractorUnderTestModel() async {
        let interactor = await makeMainActorTitleInteractor()
        let model = await TestModel(initialState: CounterState(), feature: Feature(interactor: interactor))
        await model.send(.titleChanged("a"))
        await model.finish()
    }

    /// A `@MainActor` test that forms its interactor and its `receive` predicate inline.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @MainActor
    func runInlineMainActorInteractorUnderTestModel() async {
        let interactor = Interact<CounterState, CounterAction> { state, action, effects in
            if case .titleChanged(let title) = action {
                state.title = title
                effects.perform {
                    await Task.yield()
                    try effects.send(.lastUpdatedAtChanged(nil))
                }
            }
        }
        let model = await TestModel(initialState: CounterState(), feature: Feature(interactor: interactor))
        await model.send(.titleChanged("a"))
        await model.receive({ _ in true })
        await model.finish()
    }
#endif
