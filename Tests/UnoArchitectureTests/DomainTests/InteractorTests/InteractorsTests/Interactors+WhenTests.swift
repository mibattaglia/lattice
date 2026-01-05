import CasePaths
import Foundation
import Testing

@testable import UnoArchitecture

// MARK: - Test Domain Models

struct ParentState: Equatable, Sendable {
    var counter: CounterInteractor.State
    var otherProperty: String
}

@CasePathable
enum ParentAction: Sendable, Equatable {
    case counter(CounterInteractor.Action)
    case otherAction
}

struct TwoCounterState: Equatable, Sendable {
    var counter1: CounterInteractor.State
    var counter2: CounterInteractor.State
}

@CasePathable
enum TwoCounterAction: Sendable {
    case counter1(CounterInteractor.Action)
    case counter2(CounterInteractor.Action)
}

@CasePathable
enum LoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded(CounterInteractor.State)
}

@CasePathable
enum LoadingAction: Sendable {
    case startLoading
    case loaded(CounterInteractor.Action)
}

// MARK: - KeyPath Tests

@Suite
@MainActor
struct WhenKeyPathTests {

    @Test
    func basicFunctionality() async throws {
        var state = ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")

        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }

        let emission = interactor.interact(state: &state, action: .counter(.increment))

        #expect(state.counter.count == 1)
        #expect(state.otherProperty == "test")

        switch emission.kind {
        case .none:
            break
        default:
            Issue.record("Expected .none emission")
        }
    }

    @Test
    func ignoresNonChildActions() async throws {
        var state = ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")

        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }

        let emission = interactor.interact(state: &state, action: .otherAction)

        #expect(state.counter.count == 0)

        switch emission.kind {
        case .none:
            break
        default:
            Issue.record("Expected .none emission")
        }
    }

    @Test
    func multipleActions() async throws {
        var state = ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")

        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            CounterInteractor()
        }

        _ = interactor.interact(state: &state, action: .counter(.increment))
        #expect(state.counter.count == 1)

        _ = interactor.interact(state: &state, action: .counter(.increment))
        #expect(state.counter.count == 2)

        _ = interactor.interact(state: &state, action: .counter(.decrement))
        #expect(state.counter.count == 1)
    }

    @Test
    func childEmissionMapsToParentAction() async throws {
        var state = ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")

        let childInteractor = Interact<CounterInteractor.State, CounterInteractor.Action> { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .action(.decrement)
            case .decrement:
                state.count -= 1
                return .none
            case .reset:
                state.count = 0
                return .none
            }
        }

        let interactor = Interactors.When<ParentState, ParentAction, _>(
            state: \.counter,
            action: \.counter
        ) {
            childInteractor
        }

        let emission = interactor.interact(state: &state, action: .counter(.increment))

        #expect(state.counter.count == 1)

        switch emission.kind {
        case .action(let action):
            #expect(action == .counter(.decrement))
        default:
            Issue.record("Expected .action emission, got \(emission.kind)")
        }
    }
}

// MARK: - Modifier Tests

@Suite
@MainActor
struct WhenModifierTests {

    @Test
    func modifierCombinesWithParent() async throws {
        var state = ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")

        let interactor = Interact<ParentState, ParentAction> { state, action in
            switch action {
            case .otherAction:
                state.otherProperty = "modified"
                return .none
            case .counter:
                return .none
            }
        }
        .when(state: \.counter, action: \.counter) {
            CounterInteractor()
        }

        _ = interactor.interact(state: &state, action: .counter(.increment))
        #expect(state.counter.count == 1)
        #expect(state.otherProperty == "test")

        _ = interactor.interact(state: &state, action: .otherAction)
        #expect(state.otherProperty == "modified")
    }

    @Test
    func multipleWhenModifiers() async throws {
        var state = TwoCounterState(
            counter1: CounterInteractor.State(count: 0),
            counter2: CounterInteractor.State(count: 10)
        )

        let interactor = Interact<TwoCounterState, TwoCounterAction> { _, _ in .none }
            .when(state: \.counter1, action: \.counter1) {
                CounterInteractor()
            }
            .when(state: \.counter2, action: \.counter2) {
                CounterInteractor()
            }

        _ = interactor.interact(state: &state, action: .counter1(.increment))
        #expect(state.counter1.count == 1)
        #expect(state.counter2.count == 10)

        _ = interactor.interact(state: &state, action: .counter2(.decrement))
        #expect(state.counter1.count == 1)
        #expect(state.counter2.count == 9)
    }
}

// MARK: - CasePath Tests

@Suite
@MainActor
struct WhenCasePathTests {

    @Test
    func basicFunctionality() async throws {
        var state = LoadingState.loaded(CounterInteractor.State(count: 0))

        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }

        let emission = interactor.interact(state: &state, action: .loaded(.increment))

        if case .loaded(let counter) = state {
            #expect(counter.count == 1)
        } else {
            Issue.record("Expected .loaded state")
        }

        switch emission.kind {
        case .none:
            break
        default:
            Issue.record("Expected .none emission")
        }
    }

    @Test
    func ignoresWhenStateDoesNotMatch() async throws {
        var state = LoadingState.idle

        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }

        let emission = interactor.interact(state: &state, action: .loaded(.increment))

        #expect(state == .idle)

        switch emission.kind {
        case .none:
            break
        default:
            Issue.record("Expected .none emission")
        }
    }

    @Test
    func ignoresNonChildActions() async throws {
        var state = LoadingState.loaded(CounterInteractor.State(count: 0))

        let interactor = Interactors.When<LoadingState, LoadingAction, _>(
            state: \.loaded,
            action: \.loaded
        ) {
            CounterInteractor()
        }

        let emission = interactor.interact(state: &state, action: .startLoading)

        if case .loaded(let counter) = state {
            #expect(counter.count == 0)
        } else {
            Issue.record("Expected .loaded state")
        }

        switch emission.kind {
        case .none:
            break
        default:
            Issue.record("Expected .none emission")
        }
    }

    @Test
    func casePathModifier() async throws {
        var state = LoadingState.loaded(CounterInteractor.State(count: 0))

        let interactor = Interact<LoadingState, LoadingAction> { state, action in
            switch action {
            case .startLoading:
                state = .loading
                return .none
            case .loaded:
                return .none
            }
        }
        .when(state: \.loaded, action: \.loaded) {
            CounterInteractor()
        }

        _ = interactor.interact(state: &state, action: .loaded(.increment))

        if case .loaded(let counter) = state {
            #expect(counter.count == 1)
        } else {
            Issue.record("Expected .loaded state")
        }

        _ = interactor.interact(state: &state, action: .startLoading)
        #expect(state == .loading)
    }
}
