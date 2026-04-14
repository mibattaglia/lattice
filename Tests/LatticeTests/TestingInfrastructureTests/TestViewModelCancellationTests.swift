import Foundation
import Testing

@testable import Lattice

actor CancellationProbe {
    private var didStart = false
    private var didCancel = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var suspensionContinuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        didStart = true
        let continuations = startContinuations
        startContinuations.removeAll()

        for continuation in continuations {
            continuation.resume()
        }
    }

    func cancel() {
        didCancel = true
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }

    func waitUntilStarted() async {
        guard !didStart else { return }

        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func suspendUntilCancelled() async {
        guard !didCancel else { return }

        await withCheckedContinuation { continuation in
            if didCancel {
                continuation.resume()
            } else {
                suspensionContinuation = continuation
            }
        }
    }

    func cancelled() -> Bool {
        didCancel
    }
}

@ObservableState
private struct CancellationState: Equatable, Sendable {
    var finished = false
}

private enum CancellationAction: Equatable, Sendable {
    case start
    case finished
}

@Interactor<CancellationState, CancellationAction>
private struct CancellationInteractor: Sendable {
    let probe: CancellationProbe

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .start:
                return .perform { [probe] in
                    await probe.markStarted()

                    await withTaskCancellationHandler {
                        await probe.suspendUntilCancelled()
                    } onCancel: {
                        Task {
                            await probe.cancel()
                        }
                    }

                    guard !Task.isCancelled else { return nil }

                    return .finished
                }

            case .finished:
                state.finished = true
                return .none
            }
        }
    }
}

@Suite
@MainActor
struct TestViewModelCancellationTests {
    @Test
    func skipInFlightEffectsCancelsRunningEffectWork() async throws {
        let probe = CancellationProbe()
        let model = makeModel(probe: probe)

        let task = try await model.send(.start)

        await probe.waitUntilStarted()

        try await model.skipInFlightEffects()
        try await task.finish()

        #expect(await probe.cancelled())
        #expect(model.domainState.finished == false)
    }

    private func makeModel(
        probe: CancellationProbe
    ) -> TestViewModel<Feature<CancellationAction, CancellationState, CancellationState>> {
        TestViewModel(
            initialDomainState: CancellationState(),
            feature: Feature(interactor: CancellationInteractor(probe: probe))
        )
    }
}
