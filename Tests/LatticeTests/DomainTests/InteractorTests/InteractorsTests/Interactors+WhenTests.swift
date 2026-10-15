import CasePaths
import Foundation
import Testing

@testable import Lattice

// MARK: - Test Domain Models

@FeatureState
struct ParentState: Equatable, Sendable {
    var counter: CounterState
    var otherProperty: String
}

@CasePathable
enum ParentAction: Sendable, Equatable {
    case counter(CounterAction)
    case otherAction
}

@FeatureState
struct TwoCounterState: Equatable, Sendable {
    var counter1: CounterState
    var counter2: CounterState
}

@CasePathable
enum TwoCounterAction: Sendable {
    case counter1(CounterAction)
    case counter2(CounterAction)
}

@CasePathable
enum LoadingAction: Sendable {
    case startLoading
    case loaded(CounterAction)
}

/// Records every action an interactor handles, in order.
private final class HandledActions<Action> {
    var actions: [Action] = []
}

@MainActor
private func makeViewModel<I: Interactor>(
    _ initialState: I.State,
    _ interactor: I
) -> ViewModel<Feature<I.Action, I.State>> where I.State: FeatureState & Equatable {
    ViewModel(initialState: initialState, feature: Feature(interactor: interactor))
}

// MARK: - KeyPath Tests

@Suite
@MainActor
struct WhenKeyPathTests {

    @Test
    func basicFunctionality() async throws {
        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }
        let viewModel = makeViewModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        let task = viewModel.sendViewEvent(.counter(.increment))

        #expect(viewModel.state.counter.count == 1)
        #expect(viewModel.state.otherProperty == "test")
        // The child performed no effect
        #expect(task == nil)
    }

    @Test
    func ignoresNonChildActions() async throws {
        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }
        let viewModel = makeViewModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        let task = viewModel.sendViewEvent(.otherAction)

        #expect(viewModel.state.counter.count == 0)
        #expect(task == nil)
    }

    @Test
    func multipleActions() async throws {
        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }
        let viewModel = makeViewModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        viewModel.sendViewEvent(.counter(.increment))
        #expect(viewModel.state.counter.count == 1)

        viewModel.sendViewEvent(.counter(.increment))
        #expect(viewModel.state.counter.count == 2)

        viewModel.sendViewEvent(.counter(.decrement))
        #expect(viewModel.state.counter.count == 1)
    }

    @Test
    func childEffectSendIsEmbeddedInTheParentAction() async throws {
        let childInteractor = Interact<CounterState, CounterAction> { state, action, effects in
            switch action {
            case .increment:
                state.count += 1
                effects.perform { try effects.send(.decrement) }
            case .decrement:
                state.count -= 1
            case .reset:
                state.count = 0
            }
        }
        let handled = HandledActions<ParentAction>()

        let interactor = Interactors.CollectInteractors<ParentState, ParentAction, _> {
            Interact { _, action, _ in handled.actions.append(action) }
            Interactors.When(state: \.counter, action: \.counter) {
                childInteractor
            }
        }
        let viewModel = makeViewModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        viewModel.sendViewEvent(.counter(.increment))

        // The child's send reaches the parent as `.counter(.decrement)` and is routed back to the
        // child before `sendViewEvent` returns.
        #expect(handled.actions == [.counter(.increment), .counter(.decrement)])
        #expect(viewModel.state.counter.count == 0)
    }
}

// MARK: - Modifier Tests

@Suite
@MainActor
struct WhenModifierTests {

    @Test
    func modifierCombinesWithParent() async throws {
        let interactor = Interact<ParentState, ParentAction> { state, action, _ in
            switch action {
            case .otherAction:
                state.otherProperty = "modified"
            case .counter:
                break
            }
        }
        .when(state: \.counter, action: \.counter) {
            CounterInteractor()
        }
        let viewModel = makeViewModel(ParentState(counter: CounterState(count: 0), otherProperty: "test"), interactor)

        viewModel.sendViewEvent(.counter(.increment))
        #expect(viewModel.state.counter.count == 1)
        #expect(viewModel.state.otherProperty == "test")

        viewModel.sendViewEvent(.otherAction)
        #expect(viewModel.state.otherProperty == "modified")
    }

    @Test
    func multipleWhenModifiers() async throws {
        let interactor = Interact<TwoCounterState, TwoCounterAction> { _, _, _ in }
            .when(state: \.counter1, action: \.counter1) {
                CounterInteractor()
            }
            .when(state: \.counter2, action: \.counter2) {
                CounterInteractor()
            }
        let viewModel = makeViewModel(
            TwoCounterState(
                counter1: CounterState(count: 0),
                counter2: CounterState(count: 10)
            ),
            interactor
        )

        viewModel.sendViewEvent(.counter1(.increment))
        #expect(viewModel.state.counter1.count == 1)
        #expect(viewModel.state.counter2.count == 10)

        viewModel.sendViewEvent(.counter2(.decrement))
        #expect(viewModel.state.counter1.count == 1)
        #expect(viewModel.state.counter2.count == 9)
    }
}

// MARK: - CasePath Tests

@Suite
@MainActor
struct WhenCasePathTests {

    @Test
    func basicFunctionality() async throws {
        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }
        let viewModel = makeViewModel(LoadingState.loaded(CounterState(count: 0)), interactor)

        let task = viewModel.sendViewEvent(.loaded(.increment))

        if case .loaded(let counter) = viewModel.state {
            #expect(counter.count == 1)
        } else {
            Issue.record("Expected .loaded state")
        }

        #expect(task == nil)
    }

    @Test
    func ignoresWhenStateDoesNotMatch() async throws {
        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }
        let viewModel = makeViewModel(LoadingState.idle, interactor)

        let task = viewModel.sendViewEvent(.loaded(.increment))

        #expect(viewModel.state == .idle)
        #expect(task == nil)
    }

    @Test
    func ignoresNonChildActions() async throws {
        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }
        let viewModel = makeViewModel(LoadingState.loaded(CounterState(count: 0)), interactor)

        let task = viewModel.sendViewEvent(.startLoading)

        if case .loaded(let counter) = viewModel.state {
            #expect(counter.count == 0)
        } else {
            Issue.record("Expected .loaded state")
        }

        #expect(task == nil)
    }

    @Test
    func casePathModifier() async throws {
        let interactor = Interact<LoadingState, LoadingAction> { state, action, _ in
            switch action {
            case .startLoading:
                state = .loading
            case .loaded:
                break
            }
        }
        .when(state: \.loaded, action: \.loaded) {
            CounterInteractor()
        }
        let viewModel = makeViewModel(LoadingState.loaded(CounterState(count: 0)), interactor)

        viewModel.sendViewEvent(.loaded(.increment))

        if case .loaded(let counter) = viewModel.state {
            #expect(counter.count == 1)
        } else {
            Issue.record("Expected .loaded state")
        }

        viewModel.sendViewEvent(.startLoading)
        #expect(viewModel.state == .loading)
    }
}
