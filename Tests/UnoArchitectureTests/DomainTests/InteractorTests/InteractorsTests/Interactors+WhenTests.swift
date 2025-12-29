import CasePaths
import Combine
import CombineSchedulers
import Foundation
import Testing

@testable import UnoArchitecture

// MARK: - Test Domain Models

struct ParentState: Equatable {
    var counter: CounterInteractor.State
    var otherProperty: String
}

@CasePathable
enum ParentAction {
    case counter(CounterInteractor.Action)
    case counterStateChanged(CounterInteractor.State)
    case otherAction
}

struct ParentStateWithTwo: Equatable {
    var counter1: CounterInteractor.State
    var counter2: CounterInteractor.State
}

@CasePathable
enum ParentActionWithTwo {
    case counter1(CounterInteractor.Action)
    case counter1StateChanged(CounterInteractor.State)
    case counter2(CounterInteractor.Action)
    case counter2StateChanged(CounterInteractor.State)
}

// MARK: - Tests

@Suite
final class WhenTests {
    private var cancellables: Set<AnyCancellable> = []

    @Test
    func whenKeyPathBasicFunctionality() async {
        let interactor = Interact<ParentState, ParentAction>(
            initialValue: ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")
        ) { state, action in
            switch action {
            case .counterStateChanged(let counterState):
                state.counter = counterState
                return .state
            case .counter, .otherAction:
                return .state
            }
        }
        .when(stateIs: \.counter, actionIs: \.counter, stateAction: \.counterStateChanged) {
            CounterInteractor()
        }

        let subject = PassthroughSubject<ParentAction, Never>()
        var receivedStates: [ParentState] = []

        await confirmation { confirmation in
            interactor.interact(subject.eraseToAnyPublisher())
                .sink { state in
                    receivedStates.append(state)
                    if receivedStates.count == 2 {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.counter(.increment))
            subject.send(completion: .finished)
        }

        // Should receive: initial state (count: 0) + state after increment (count: 1)
        // Child actions are filtered out - only state change actions reach parent
        #expect(receivedStates.count == 2)

        // First state is initial parent state with child's initial state (count: 0)
        #expect(receivedStates[0].counter.count == 0)
        #expect(receivedStates[0].otherProperty == "test")

        // Second state reflects the increment via stateChanged
        #expect(receivedStates[1].counter.count == 1)
        #expect(receivedStates[1].otherProperty == "test")
    }

    @Test
    func whenFiltersNonChildActions() async {
        let interactor = Interact<ParentState, ParentAction>(
            initialValue: ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")
        ) { state, action in
            switch action {
            case .counterStateChanged(let counterState):
                state.counter = counterState
                return .state
            case .counter:
                return .state
            case .otherAction:
                state.otherProperty = "modified"
                return .state
            }
        }
        .when(stateIs: \.counter, actionIs: \.counter, stateAction: \.counterStateChanged) {
            CounterInteractor()
        }

        let subject = PassthroughSubject<ParentAction, Never>()
        var receivedStates: [ParentState] = []

        await confirmation { confirmation in
            interactor.interact(subject.eraseToAnyPublisher())
                .sink { state in
                    receivedStates.append(state)
                    if receivedStates.count == 2 {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.otherAction)
            subject.send(completion: .finished)
        }

        // Should receive: initial state + state after otherAction
        #expect(receivedStates.count == 2)

        // First state is initial
        #expect(receivedStates[0].counter.count == 0)
        #expect(receivedStates[0].otherProperty == "test")

        // Second state has modified otherProperty
        #expect(receivedStates[1].otherProperty == "modified")
        #expect(receivedStates[1].counter.count == 0)  // Counter unchanged
    }

    @Test
    func whenMultipleChildActions() async {
        let interactor = Interact<ParentState, ParentAction>(
            initialValue: ParentState(counter: CounterInteractor.State(count: 0), otherProperty: "test")
        ) { state, action in
            switch action {
            case .counterStateChanged(let counterState):
                state.counter = counterState
                return .state
            case .counter, .otherAction:
                return .state
            }
        }
        .when(stateIs: \.counter, actionIs: \.counter, stateAction: \.counterStateChanged) {
            CounterInteractor()
        }

        let subject = PassthroughSubject<ParentAction, Never>()
        var receivedStates: [ParentState] = []

        await confirmation { confirmation in
            interactor.interact(subject.eraseToAnyPublisher())
                .sink { state in
                    receivedStates.append(state)
                    if receivedStates.count == 4 {  // initial + 3 state changes
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.counter(.increment))  // count: 0 -> 1
            subject.send(.counter(.increment))  // count: 1 -> 2
            subject.send(.counter(.decrement))  // count: 2 -> 1
            subject.send(completion: .finished)
        }

        #expect(receivedStates.count == 4)

        // Child actions are filtered - only state changes reach parent
        let counterValues = receivedStates.map { $0.counter.count }
        #expect(counterValues == [0, 1, 2, 1])
    }

    @Test
    func whenChainingMultipleModifiers() async {
        let interactor = Interact<ParentStateWithTwo, ParentActionWithTwo>(
            initialValue: ParentStateWithTwo(
                counter1: CounterInteractor.State(count: 0),
                counter2: CounterInteractor.State(count: 10)
            )
        ) { state, action in
            switch action {
            case .counter1StateChanged(let counterState):
                state.counter1 = counterState
                return .state
            case .counter2StateChanged(let counterState):
                state.counter2 = counterState
                return .state
            case .counter1, .counter2:
                return .state
            }
        }
        .when(stateIs: \.counter1, actionIs: \.counter1, stateAction: \.counter1StateChanged) {
            CounterInteractor()
        }
        .when(stateIs: \.counter2, actionIs: \.counter2, stateAction: \.counter2StateChanged) {
            Interact<CounterInteractor.State, CounterInteractor.Action>(initialValue: CounterInteractor.State(count: 10)) { state, action in
                switch action {
                case .increment:
                    state.count += 1
                    return .state
                case .decrement:
                    state.count -= 1
                    return .state
                case .reset:
                    state.count = 10
                    return .state
                }
            }
        }

        let subject = PassthroughSubject<ParentActionWithTwo, Never>()
        var receivedStates: [ParentStateWithTwo] = []

        await confirmation { confirmation in
            interactor.interact(subject.eraseToAnyPublisher())
                .sink { state in
                    receivedStates.append(state)
                    if receivedStates.count == 3 {  // initial + 2 state changes
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.counter1(.increment))  // counter1: 0 -> 1
            subject.send(.counter2(.decrement))  // counter2: 10 -> 9
            subject.send(completion: .finished)
        }

        #expect(receivedStates.count == 3)

        // Initial state
        #expect(receivedStates[0].counter1.count == 0)
        #expect(receivedStates[0].counter2.count == 10)

        // After counter1 state changed
        #expect(receivedStates[1].counter1.count == 1)
        #expect(receivedStates[1].counter2.count == 10)

        // After counter2 state changed
        #expect(receivedStates[2].counter1.count == 1)
        #expect(receivedStates[2].counter2.count == 9)
    }
}
