import Foundation
import Lattice
import Testing

@ObservableState
private struct EventTaskState: Equatable, Sendable {
    var log: [String] = []
}

private actor EventTaskProbe {
    private var didStartChildEffect = false
    private var didCancelChildEffect = false

    func markChildEffectStarted() {
        didStartChildEffect = true
    }

    func markChildEffectCancelled() {
        didCancelChildEffect = true
    }

    func childEffectStarted() -> Bool {
        didStartChildEffect
    }

    func childEffectCancelled() -> Bool {
        didCancelChildEffect
    }
}

private enum EventTaskAction: Sendable {
    case start
    case firstResponse
    case secondResponse
}

@Interactor<EventTaskState, EventTaskAction>
private struct EventTaskInteractor: Interactor {
    let probe: EventTaskProbe

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .start:
                state.log.append("start")
                return .perform {
                    return .firstResponse
                }

            case .firstResponse:
                state.log.append("first")
                return .perform { [probe] in
                    await probe.markChildEffectStarted()

                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        await probe.markChildEffectCancelled()
                        return nil
                    }

                    return .secondResponse
                }

            case .secondResponse:
                state.log.append("second")
                return .none
            }
        }
    }
}

@MainActor
@Suite(.serialized)
struct EventTaskTests {
    @Test
    func finishAwaitsRecursiveChildEffects() async {
        let probe = EventTaskProbe()
        let viewModel = makeViewModel(probe: probe)

        await viewModel.sendViewEvent(.start).finish()

        #expect(viewModel.viewState.log == ["start", "first", "second"])
    }

    @Test
    func cancelCancelsChildEffectsInTheSameRootScope() async {
        let probe = EventTaskProbe()
        let viewModel = makeViewModel(probe: probe)

        let task = viewModel.sendViewEvent(.start)
        await waitUntil { await probe.childEffectStarted() }

        task.cancel()
        await task.finish()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(viewModel.viewState.log == ["start", "first"])
        #expect(await probe.childEffectCancelled())
    }

    private func makeViewModel(
        probe: EventTaskProbe
    ) -> ViewModel<Feature<EventTaskAction, EventTaskState, EventTaskState>> {
        ViewModel(
            initialDomainState: EventTaskState(),
            feature: Feature(
                interactor: EventTaskInteractor(probe: probe).eraseToAnyInteractorUnchecked()
            )
        )
    }

    private func waitUntil(
        iterations: Int = 200,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await condition() {
                return
            }

            await Task.yield()
        }

        Issue.record("Timed out waiting for asynchronous condition")
    }
}
