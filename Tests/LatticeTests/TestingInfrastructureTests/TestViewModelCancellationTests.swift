// Plan 07 §9: cancellation scenarios migrated from the Emission-era suite.
// `skipInFlightEffects` is deleted — `dismount()` or `TestEventTask.cancel()` covers the
// intent.

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

private struct CancellationState: Equatable {
    var finished = false
}

private enum CancellationAction: Equatable {
    case start
}

private struct CancellationInteractor: Interactor {
    let probe: CancellationProbe

    var body: some Interactor<CancellationState, CancellationAction> {
        Interact { [probe] state, action, effects in
            switch action {
            case .start:
                effects.perform { effectState in
                    await probe.markStarted()

                    await withTaskCancellationHandler {
                        await probe.suspendUntilCancelled()
                    } onCancel: {
                        Task {
                            await probe.cancel()
                        }
                    }

                    guard !Task.isCancelled else { return }

                    try effectState.modify { $0.finished = true }
                }
            }
        }
    }
}

extension TestingInfrastructureTests {
    @Suite
    @MainActor
    struct TestViewModelCancellationTests {
    @Test
    func testEventTaskCancelCancelsRunningEffectWork() async {
        let probe = CancellationProbe()
        let model = makeModel(probe: probe)

        let task = await model.send(.start)

        await probe.waitUntilStarted()

        await task.cancel()

        #expect(await probe.cancelled())
        #expect(model.domainState.finished == false)
    }

    @Test
    func testEventTaskCanCancelImmediatelyAfterSendReturns() async {
        let probe = CancellationProbe()
        let model = makeModel(probe: probe)

        let task = await model.send(.start)

        await task.cancel()

        #expect(await probe.cancelled())
        #expect(model.domainState.finished == false)
    }

    @Test
    func dismountCancelsRunningEffectWork() async {
        let probe = CancellationProbe()
        let model = makeModel(probe: probe)

        let task = await model.send(.start)

        await probe.waitUntilStarted()

        await model.dismount(timeout: .seconds(1))
        await task.finish()

        #expect(await probe.cancelled())
        #expect(model.domainState.finished == false)
    }

    private func makeModel(
        probe: CancellationProbe
    ) -> TestViewModel<CancellationState, CancellationAction> {
        TestViewModel(
            initialDomainState: CancellationState(),
            interactor: CancellationInteractor(probe: probe)
        )
    }
}
}
