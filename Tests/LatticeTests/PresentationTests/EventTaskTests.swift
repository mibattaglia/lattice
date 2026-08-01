// Rewritten around the flipped EventTask semantics (plan 06 §2): the handle wraps the
// composite task over the effects its send launched *directly*.

import CasePaths
import Clocks
import Foundation
import Testing

@testable import Lattice

// MARK: - Fixtures

@FeatureState
private struct EffectsVMState {
    var log: [String] = []
    var value: Int = 0
}

private enum EffectsVMEvent {
    case noEffect
    case oneEffect
    case chained
    case chainedSecondStage
    case modifyOnly
    case slowEffect
    case synchronousEffect
}

/// Shared mutable recorder for smuggling values out of effects. Everything here runs in the
/// MainActor domain by construction; `@unchecked Sendable` only so a synchronous observer
/// closure may capture it.
private final class Box: @unchecked Sendable {
    var secondGenerationTask: Task<Void, Never>??
    var reentrantEventTask: EventTask?
}

private struct EffectsVMInteractor: Interactor {
    let clock: TestClock<Duration>
    let box: Box

    var body: some Interactor<EffectsVMState, EffectsVMEvent> {
        Interact { [clock, box] state, action, effects in
            switch action {
            case .noEffect:
                state.value += 1

            case .oneEffect:
                effects.perform { effectState in
                    try await clock.sleep(for: .seconds(1))
                    try effectState.modify { $0.log.append("one") }
                }

            case .chained:
                effects.perform { effectState in
                    try await clock.sleep(for: .seconds(1))
                    try effectState.modify { $0.log.append("first") }
                    // Re-entry: an independent unit with its own composite task.
                    box.secondGenerationTask = try effectState.send(.chainedSecondStage)
                }

            case .chainedSecondStage:
                effects.perform { effectState in
                    try await clock.sleep(for: .seconds(1))
                    try effectState.modify { $0.log.append("second") }
                }

            case .modifyOnly:
                effects.perform { effectState in
                    try effectState.modify { $0.log.append("modified") }
                }

            case .slowEffect:
                effects.perform { effectState in
                    try await clock.sleep(for: .seconds(10))
                    try effectState.modify { $0.log.append("slow") }
                }

            case .synchronousEffect:
                effects.perform { effectState in
                    // No suspension point: completes synchronously at launch.
                    try effectState.modify { $0.log.append("sync") }
                }
            }
        }
    }
}

// MARK: - Case-exit fixture

@FeatureState
private struct ChildEffectState {
    var progress: Int = 0
}

private enum ChildEffectAction {
    case begin
}

private struct ChildEffectInteractor: Interactor {
    let clock: TestClock<Duration>

    var body: some Interactor<ChildEffectState, ChildEffectAction> {
        Interact { [clock] state, action, effects in
            switch action {
            case .begin:
                effects.perform { effectState in
                    try await clock.sleep(for: .seconds(10))
                    try effectState.modify { $0.progress = 100 }
                }
            }
        }
    }
}

@FeatureState
@CasePathable
private enum RouteEffectState {
    case idle
    case active(ChildEffectState)
}

@CasePathable
private enum RouteEffectAction {
    case dismiss
    case child(ChildEffectAction)
}

private struct RouteEffectInteractor: Interactor {
    let clock: TestClock<Duration>

    var body: some Interactor<RouteEffectState, RouteEffectAction> {
        Interactors.When(state: \.active, action: \.child) {
            ChildEffectInteractor(clock: clock)
        }
        Interact { state, action in
            if case .dismiss = action {
                state = .idle
            }
        }
    }
}

// MARK: - Tests

@MainActor
@Suite
struct EventTaskTests {

    private func makeViewModel(
        clock: TestClock<Duration> = TestClock(),
        box: Box = Box()
    ) -> ViewModel<EffectsVMState, EffectsVMEvent> {
        ViewModel(
            initialState: EffectsVMState(),
            interactor: EffectsVMInteractor(clock: clock, box: box)
        )
    }

    // (1) No `perform` → no effects, immediate finish.
    @Test
    func noEffectSendHasNoEffectsAndFinishesImmediately() async {
        let viewModel = makeViewModel()

        let task = viewModel.sendViewEvent(.noEffect)

        #expect(task.hasEffects == false)
        await task.finish()  // returns immediately
        #expect(viewModel.value == 1)
    }

    // (2) Single perform → finish awaits it.
    @Test
    func finishAwaitsTheLaunchedEffect() async {
        let clock = TestClock()
        let viewModel = makeViewModel(clock: clock)

        let task = viewModel.sendViewEvent(.oneEffect)
        #expect(task.hasEffects == true)
        #expect(viewModel.log.isEmpty)

        await clock.advance(by: .seconds(1))
        await task.finish()

        #expect(viewModel.log == ["one"])
    }

    // (3) Direct-only coverage: a re-entrant `effectState.send`'s work is an independent
    // unit; the original finish() returns without awaiting it, and the task returned by
    // `effectState.send` awaits it.
    @Test
    func finishCoversOnlyDirectlyLaunchedEffects() async {
        let clock = TestClock()
        let box = Box()
        let viewModel = makeViewModel(clock: clock, box: box)

        let task = viewModel.sendViewEvent(.chained)

        await clock.advance(by: .seconds(1))
        await task.finish()

        // The first generation completed; the second is still suspended on the clock.
        #expect(viewModel.log == ["first"])

        let secondTask = try! #require(box.secondGenerationTask)
        await clock.advance(by: .seconds(1))
        await secondTask?.value

        #expect(viewModel.log == ["first", "second"])
    }

    // (4) `modify` does not extend the handle (it spawns no work; the effect that called it
    // is the only covered unit).
    @Test
    func modifyDoesNotExtendTheHandle() async {
        let viewModel = makeViewModel()

        let task = viewModel.sendViewEvent(.modifyOnly)
        #expect(task.hasEffects == true)

        await task.finish()
        #expect(viewModel.log == ["modified"])
    }

    // (5) cancel() cancels the send's in-flight effects; finish() returns after wind-down.
    @Test
    func cancelCancelsInFlightEffectsAndFinishReturns() async {
        let clock = TestClock()
        let viewModel = makeViewModel(clock: clock)

        let task = viewModel.sendViewEvent(.slowEffect)
        task.cancel()
        await task.finish()

        #expect(task.isCancelled)
        #expect(viewModel.log.isEmpty)
    }

    // (6) Auto-replacement across two sends: the first handle finishes at replaced-task
    // wind-down; the second owns the replacement.
    @Test
    func autoReplacementFinishesTheReplacedHandle() async {
        let clock = TestClock()
        let viewModel = makeViewModel(clock: clock)

        let first = viewModel.sendViewEvent(.oneEffect)
        let second = viewModel.sendViewEvent(.oneEffect)

        // The second send replaced (cancelled) the first task at the same call site, so the
        // first handle finishes without its effect completing.
        await first.finish()
        #expect(viewModel.log.isEmpty)

        await clock.advance(by: .seconds(1))
        await second.finish()
        #expect(viewModel.log == ["one"])
    }

    // (7) A case-exit commit cancels the child's effects → finish() returns without effect
    // completion.
    @Test
    func caseExitCancelsChildEffectsAndFinishReturns() async {
        let clock = TestClock()
        let viewModel = ViewModel(
            initialState: RouteEffectState.active(ChildEffectState()),
            interactor: RouteEffectInteractor(clock: clock)
        )

        let task = viewModel.sendViewEvent(.child(.begin))
        #expect(task.hasEffects == true)

        viewModel.sendViewEvent(.dismiss)
        await task.finish()

        // The effect never completed: the case departed and its bucket was cancelled.
        if case .active = viewModel._observedState {
            Issue.record("Expected .idle after dismiss")
        }
    }

    // (8) A reentrant send from a synchronous observer runs recursively and returns its own
    // live EventTask.
    @Test
    func reentrantSendFromSynchronousObserverReturnsItsOwnHandle() async {
        let clock = TestClock()
        let box = Box()
        let viewModel = makeViewModel(clock: clock, box: box)

        withObservationTracking {
            _ = viewModel.value
        } onChange: {
            MainActor.assumeIsolated {
                box.reentrantEventTask = viewModel.sendViewEvent(.oneEffect)
            }
        }

        // Commits synchronously; the observer's recursive send runs before this returns.
        viewModel.sendViewEvent(.noEffect)

        let reentrant = try! #require(box.reentrantEventTask)
        #expect(reentrant.hasEffects == true)
        #expect(viewModel.value == 1)

        await clock.advance(by: .seconds(1))
        await reentrant.finish()
        #expect(viewModel.log == ["one"])
    }

    // (9) An effect that completes synchronously still counts as launched.
    @Test
    func synchronouslyCompletingEffectStillCountsAsLaunched() async {
        let viewModel = makeViewModel()

        let task = viewModel.sendViewEvent(.synchronousEffect)

        #expect(task.hasEffects == true)
        await task.finish()  // returns immediately
        #expect(viewModel.log == ["sync"])
    }
}
