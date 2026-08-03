// The deinit story: `ViewModel` has no deinit — teardown is the
// core storage's plain deinit cancelling every task bucket; effects hold the core weakly.

import Clocks
import Foundation
import Testing

@testable import Lattice

// MARK: - Fixtures

/// Deinit canary: lives inside the domain state, so its `deinit` runs when the core —
/// the state's owner — is released.
private final class LifetimeCanary {
    let onDeinit: () -> Void
    init(onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
    deinit { onDeinit() }
}

@FeatureState
private struct DeinitState {
    @Domain var canary: LifetimeCanary?
    var value: Int = 0
}

private enum DeinitEvent {
    case startSlowEffect
    case startObservedEffect
}

/// Plain recorder; MainActor-confined by usage.
private final class Probe {
    var effectSawCancellation = false
    var modifyThrewCancellation = false
    var effectState: EffectState<DeinitState, DeinitEvent>?
}

private struct DeinitInteractor: Interactor {
    let clock: TestClock<Duration>
    let probe: Probe

    var body: some Interactor<DeinitState, DeinitEvent> {
        Interact { [clock, probe] state, action, effects in
            switch action {
            case .startSlowEffect:
                effects.perform { effectState in
                    try await clock.sleep(for: .seconds(100))
                    try effectState.modify { $0.value += 1 }
                }

            case .startObservedEffect:
                effects.perform { effectState in
                    probe.effectState = effectState
                    do {
                        try await clock.sleep(for: .seconds(100))
                    } catch is CancellationError {
                        probe.effectSawCancellation = true
                        do {
                            try effectState.modify { $0.value += 1 }
                        } catch {
                            probe.modifyThrewCancellation = true
                        }
                        throw CancellationError()
                    }
                }
            }
        }
    }
}

// MARK: - Tests

@MainActor
@Suite
struct ViewModelDeinitTests {

    // (1) Releasing the ViewModel with an in-flight effect cancels it.
    @Test
    func releasingTheViewModelCancelsInFlightEffects() async {
        let clock = TestClock()
        let probe = Probe()

        var viewModel: ViewModel<DeinitState, DeinitEvent>? = ViewModel(
            initialState: DeinitState(),
            interactor: DeinitInteractor(clock: clock, probe: probe)
        )

        let task = viewModel!.sendViewEvent(.startObservedEffect)
        #expect(task.hasEffects == true)

        viewModel = nil
        await task.finish()

        #expect(probe.effectSawCancellation)
    }

    // (2) A parked finish() resumes when the ViewModel is released.
    @Test
    func parkedFinishResumesOnRelease() async {
        let clock = TestClock()
        let probe = Probe()

        var viewModel: ViewModel<DeinitState, DeinitEvent>? = ViewModel(
            initialState: DeinitState(),
            interactor: DeinitInteractor(clock: clock, probe: probe)
        )

        let task = viewModel!.sendViewEvent(.startSlowEffect)

        let parked = Task {
            await task.finish()
            return true
        }

        viewModel = nil
        #expect(await parked.value)
    }

    // (3) An outstanding EventTask held after release does not keep the core alive
    // (deinit-side-effect canary on state owned by the core).
    @Test
    func outstandingEventTaskDoesNotKeepTheCoreAlive() async {
        let clock = TestClock()
        let probe = Probe()

        var coreDidDeinit = false
        var viewModel: ViewModel<DeinitState, DeinitEvent>? = ViewModel(
            initialState: DeinitState(canary: LifetimeCanary { coreDidDeinit = true }),
            interactor: DeinitInteractor(clock: clock, probe: probe)
        )

        let task = viewModel!.sendViewEvent(.startSlowEffect)

        viewModel = nil
        await task.finish()

        // `task` is still held here, yet the core (and its state) are gone.
        #expect(coreDidDeinit)
        #expect(task.hasEffects == true)
    }

    // (4) A post-teardown modify throws CancellationError (the same contract effect
    // handles observe when their scope is gone).
    @Test
    func postTeardownModifyThrowsCancellationError() async {
        let clock = TestClock()
        let probe = Probe()

        var viewModel: ViewModel<DeinitState, DeinitEvent>? = ViewModel(
            initialState: DeinitState(),
            interactor: DeinitInteractor(clock: clock, probe: probe)
        )

        let task = viewModel!.sendViewEvent(.startObservedEffect)

        viewModel = nil
        await task.finish()

        #expect(probe.effectSawCancellation)
        #expect(probe.modifyThrewCancellation)

        // The handle smuggled out of the effect also throws now that the core is gone.
        // (Calling from an uncancelled context also reports a dismounted-handle issue.)
        var lateModifyThrew = false
        withKnownIssue {
            do {
                try probe.effectState?.modify { $0.value += 1 }
            } catch {
                lateModifyThrew = true
            }
        }
        #expect(lateModifyThrew)
    }
}
