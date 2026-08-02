// Core `ViewModel` behavior: fixtures on `@FeatureState` types and the
// `interact(state:action:effects:)` shape. Which-keys-fired granularity assertions live
// in the registrar/projection suites, not here.

import Foundation
import Testing

import Clocks

@testable import Lattice

// MARK: - Fixtures

@FeatureState
private struct CounterVMState {
    @Domain var hiddenTicks: Int = 0
    var count: Int = 0
    var isLoading: Bool = false
    var label: String {
        "Count: \(count)"
    }
}

private enum CounterVMEvent {
    case increment
    case tickDomainOnly
    case touchNothing
    case fetch
}

private struct CounterVMInteractor: Interactor {
    var clock: TestClock<Duration> = TestClock()

    var body: some Interactor<CounterVMState, CounterVMEvent> {
        Interact { [clock] state, action, effects in
            switch action {
            case .increment:
                state.count += 1
            case .tickDomainOnly:
                state.hiddenTicks += 1
            case .touchNothing:
                break
            case .fetch:
                state.isLoading = true
                effects.perform { effectState in
                    try await clock.sleep(for: .seconds(1))
                    try effectState.modify {
                        $0.isLoading = false
                        $0.count = 42
                    }
                }
            }
        }
    }
}

// MARK: - Non-Sendable fixture (the point of the rework)

private final class NonSendableCounterService {
    var calls = 0
    func next() -> Int {
        calls += 1
        return calls
    }
}

@FeatureState
private struct NonSendableVMState {
    @Domain var service = NonSendableCounterService()
    var value: Int = 0
}

private enum NonSendableVMEvent {
    case advance(NonSendableCounterService)
}

private struct NonSendableVMInteractor: Interactor {
    var body: some Interactor<NonSendableVMState, NonSendableVMEvent> {
        Interact { state, action in
            switch action {
            case .advance(let service):
                state.value = service.next()
            }
        }
    }
}

// MARK: - Tests

@MainActor
@Suite
struct ViewModelTests {

    @Test
    func sendMutatesDomainStateAndProjectedMembersReflectIt() {
        let viewModel = ViewModel(
            initialState: CounterVMState(),
            interactor: CounterVMInteractor()
        )

        #expect(viewModel.count == 0)

        viewModel.sendViewEvent(.increment)
        #expect(viewModel.count == 1)

        viewModel.sendViewEvent(.increment)
        #expect(viewModel.count == 2)
    }

    @Test
    func dynamicMemberReadsRouteThroughTheProjection() {
        let viewModel = ViewModel(
            initialState: CounterVMState(),
            interactor: CounterVMInteractor()
        )

        // Stored member, derived member, and repeated derived reads (served consistently).
        #expect(viewModel.isLoading == false)
        #expect(viewModel.label == "Count: 0")

        viewModel.sendViewEvent(.increment)
        #expect(viewModel.label == "Count: 1")
        #expect(viewModel.label == "Count: 1")
    }

    @Test
    func commitThatChangesNothingVisibleFiresNoRegistrarKeys() {
        let viewModel = ViewModel(
            initialState: CounterVMState(),
            interactor: CounterVMInteractor()
        )

        // Observe some members so their signals exist.
        _ = viewModel.count
        _ = viewModel.label

        var poked: [ProjectionKey] = []
        viewModel.registrar.onPoke = { poked.append($0) }

        // A commit that mutates nothing fires nothing.
        viewModel.sendViewEvent(.touchNothing)
        #expect(poked.isEmpty)

        // A domain-only commit (visible members unchanged, derived output unchanged)
        // fires nothing either: the gate is per member, inside `_commit`.
        viewModel.sendViewEvent(.tickDomainOnly)
        #expect(poked.isEmpty)

        // A visible change fires.
        viewModel.sendViewEvent(.increment)
        #expect(!poked.isEmpty)
    }

    @Test
    func modifyFromAnEffectUpdatesTheProjection() async {
        let clock = TestClock()
        let viewModel = ViewModel(
            initialState: CounterVMState(),
            interactor: CounterVMInteractor(clock: clock)
        )

        let task = viewModel.sendViewEvent(.fetch)

        // Synchronous update-phase mutation is committed before sendViewEvent returns.
        #expect(viewModel.isLoading == true)

        await clock.advance(by: .seconds(1))
        await task.finish()

        // The effect's `modify` committed through the same funnel.
        #expect(viewModel.isLoading == false)
        #expect(viewModel.count == 42)
    }

    @Test
    func nonSendableDomainStateAndActionCompileAndRun() {
        let service = NonSendableCounterService()
        let viewModel = ViewModel(
            initialState: NonSendableVMState(),
            interactor: NonSendableVMInteractor()
        )

        viewModel.sendViewEvent(.advance(service))
        #expect(viewModel.value == 1)

        viewModel.sendViewEvent(.advance(service))
        #expect(viewModel.value == 2)
        #expect(service.calls == 2)
    }
}
