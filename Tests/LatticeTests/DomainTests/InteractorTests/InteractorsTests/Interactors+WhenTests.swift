// Destructive rewrite for the effects-only interactor shape (plan 04 test suite 2,
// executed at plan 06's flip): `When` routing/embedding semantics on the new
// `interact(state:action:effects:)` signature. Scoped-handle effects routing (drop/cancel
// on case departure, lens pullback) is covered by `WhenEffectsRoutingTests`.

import CasePaths
import Foundation
import Testing

@testable import Lattice

// MARK: - Test Domain Models

private struct CounterState: Equatable {
    var count = 0
}

private enum CounterAction: Equatable {
    case increment
    case decrement
    case reset
}

private struct CounterInteractor: Interactor {
    var body: some Interactor<CounterState, CounterAction> {
        Interact { state, action in
            switch action {
            case .increment: state.count += 1
            case .decrement: state.count -= 1
            case .reset: state.count = 0
            }
        }
    }
}

private struct ParentState: Equatable {
    var counter: CounterState
    var otherProperty: String
}

@CasePathable
private enum ParentAction: Equatable {
    case counter(CounterAction)
    case otherAction
}

private struct TwoCounterState: Equatable {
    var counter1: CounterState
    var counter2: CounterState
}

@CasePathable
private enum TwoCounterAction {
    case counter1(CounterAction)
    case counter2(CounterAction)
}

@CasePathable
private enum LoadingState: Equatable {
    case idle
    case loading
    case loaded(CounterState)
}

@CasePathable
private enum LoadingAction {
    case startLoading
    case loaded(CounterAction)
}

private func detached<State, Action>() -> Effects<State, Action> {
    _detachedEffectsHandle(path: GraphPath())
}

// MARK: - KeyPath Tests

@Suite
@MainActor
struct WhenKeyPathTests {

    @Test
    func basicFunctionality() throws {
        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }

        interactor.interact(state: &state, action: .counter(.increment), effects: detached())

        #expect(state.counter.count == 1)
        #expect(state.otherProperty == "test")
    }

    @Test
    func ignoresNonChildActions() throws {
        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }

        interactor.interact(state: &state, action: .otherAction, effects: detached())

        #expect(state.counter.count == 0)
    }

    @Test
    func multipleActions() throws {
        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }

        interactor.interact(state: &state, action: .counter(.increment), effects: detached())
        #expect(state.counter.count == 1)

        interactor.interact(state: &state, action: .counter(.increment), effects: detached())
        #expect(state.counter.count == 2)

        interactor.interact(state: &state, action: .counter(.decrement), effects: detached())
        #expect(state.counter.count == 1)
    }
}

// MARK: - Modifier Tests

@Suite
@MainActor
struct WhenModifierTests {

    @Test
    func modifierCombinesWithParent() throws {
        var state = ParentState(counter: CounterState(count: 0), otherProperty: "test")

        let interactor = Interact<ParentState, ParentAction> { state, action in
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

        interactor.interact(state: &state, action: .counter(.increment), effects: detached())
        #expect(state.counter.count == 1)
        #expect(state.otherProperty == "test")

        interactor.interact(state: &state, action: .otherAction, effects: detached())
        #expect(state.otherProperty == "modified")
    }

    @Test
    func multipleWhenModifiers() throws {
        var state = TwoCounterState(
            counter1: CounterState(count: 0),
            counter2: CounterState(count: 10)
        )

        let interactor = Interact<TwoCounterState, TwoCounterAction> { _, _ in }
            .when(state: \.counter1, action: \.counter1) {
                CounterInteractor()
            }
            .when(state: \.counter2, action: \.counter2) {
                CounterInteractor()
            }

        interactor.interact(state: &state, action: .counter1(.increment), effects: detached())
        #expect(state.counter1.count == 1)
        #expect(state.counter2.count == 10)

        interactor.interact(state: &state, action: .counter2(.decrement), effects: detached())
        #expect(state.counter1.count == 1)
        #expect(state.counter2.count == 9)
    }
}

// MARK: - CasePath Tests

@Suite
@MainActor
struct WhenCasePathTests {

    @Test
    func basicFunctionality() throws {
        var state = LoadingState.loaded(CounterState(count: 0))

        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }

        interactor.interact(state: &state, action: .loaded(.increment), effects: detached())

        if case .loaded(let counter) = state {
            #expect(counter.count == 1)
        } else {
            Issue.record("Expected .loaded state")
        }
    }

    @Test
    func ignoresWhenStateDoesNotMatch() throws {
        var state = LoadingState.idle

        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }

        interactor.interact(state: &state, action: .loaded(.increment), effects: detached())

        #expect(state == .idle)
    }

    @Test
    func ignoresNonChildActions() throws {
        var state = LoadingState.loaded(CounterState(count: 0))

        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }

        interactor.interact(state: &state, action: .startLoading, effects: detached())

        if case .loaded(let counter) = state {
            #expect(counter.count == 0)
        } else {
            Issue.record("Expected .loaded state")
        }
    }

    @Test
    func casePathModifier() throws {
        var state = LoadingState.loaded(CounterState(count: 0))

        let interactor = Interact<LoadingState, LoadingAction> { state, action in
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

        interactor.interact(state: &state, action: .loaded(.increment), effects: detached())

        if case .loaded(let counter) = state {
            #expect(counter.count == 1)
        } else {
            Issue.record("Expected .loaded state")
        }

        interactor.interact(state: &state, action: .startLoading, effects: detached())
        #expect(state == .loading)
    }
}
