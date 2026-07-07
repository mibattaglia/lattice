import CasePaths
import Foundation
import Observation
import Testing

@testable import Lattice

@MainActor
@Suite
struct ViewModelReentrancyTests {
    // Regression test for an exclusive-access crash: during a reduce, an in-place tracked
    // mutation fires the observation `willSet`. A synchronous observer (e.g. SwiftUI
    // re-evaluating `body` inside that `willSet`) re-reads `viewModel.viewState.getter`
    // while the reducer is still running. If the reducer held a formal write access on the
    // stored view state open across its body (as the former `viewState` `_modify` accessor
    // did), the re-entrant read trapped with "Fatal access conflict detected".
    @Test
    func synchronousReadDuringReduceMutation() {
        let viewModel = makeViewModel(reducer: CounterPhaseReducer())

        withObservationTracking {
            _ = viewModel.viewState.phase
        } onChange: {
            // Re-enter the getter synchronously, exactly as SwiftUI body re-evaluation can.
            // `onChange` fires from `withMutation`'s `willSet`, which the reducer triggers
            // mid-reduce.
            MainActor.assumeIsolated {
                _ = viewModel.viewState
            }
        }

        viewModel.sendViewEvent(.increment)

        #expect(viewModel.viewState.phase.active?.value == "1")
    }

    private func makeViewModel<R: ViewStateReducer & Sendable>(
        reducer: R
    ) -> ViewModel<Feature<CounterPhaseAction, CounterPhaseDomainState, CounterPhaseViewState>>
    where R.DomainState == CounterPhaseDomainState, R.ViewState == CounterPhaseViewState {
        ViewModel(
            initialDomainState: .init(count: 0),
            feature: Feature(interactor: CounterPhaseInteractor(), reducer: reducer)
        )
    }
}

private struct CounterPhaseInteractor: Interactor, Sendable {
    typealias DomainState = CounterPhaseDomainState
    typealias Action = CounterPhaseAction

    var body: some InteractorOf<Self> { self }

    func interact(
        state: inout CounterPhaseDomainState,
        action: CounterPhaseAction
    ) -> Emission<CounterPhaseAction> {
        switch action {
        case .increment:
            state.count += 1
            return .none
        }
    }
}

private struct CounterPhaseReducer: ViewStateReducer, Sendable {
    typealias DomainState = CounterPhaseDomainState
    typealias ViewState = CounterPhaseViewState

    var body: some ViewStateReducerOf<Self> { self }

    func initialViewState(for domainState: CounterPhaseDomainState) -> CounterPhaseViewState {
        CounterPhaseViewState.defaultValue
    }

    func reduce(_ domainState: CounterPhaseDomainState, into viewState: inout CounterPhaseViewState) {
        viewState.phase = .active(.init(value: "\(domainState.count)"))
    }
}

@ObservableState
private struct CounterPhaseViewState: Equatable, Sendable, DefaultValueProvider {
    static let defaultValue = Self(phase: .active(.init(value: "0")))

    var phase: CounterPhase
}

@ObservableState
@CasePathable
@dynamicMemberLookup
private enum CounterPhase: Equatable, Sendable {
    case idle
    case active(CounterPhasePayload)
}

@ObservableState
private struct CounterPhasePayload: Equatable, Sendable {
    var value: String
}

private struct CounterPhaseDomainState: Equatable, Sendable {
    var count = 0
}

@CasePathable
private enum CounterPhaseAction: Sendable {
    case increment
}
