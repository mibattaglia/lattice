import CasePaths
import Combine
import CombineSchedulers
import Foundation
import Testing

@testable import UnoArchitecture

// MARK: - Test Domain Models

struct ParentState {
    var counter: CounterInteractor.State
    var otherProperty: String
}

@CasePathable
enum ParentAction {
    case counter(CounterInteractor.Action)
    case counterStateChanged(CounterInteractor.State)
    case otherAction
}

// MARK: - Tests

@Suite
final class WhenTests {
    private var cancellables: Set<AnyCancellable> = []

    @Test
    func whenKeyPathBasicFunctionality() async {
        let whenInteractor = When<ParentState, ParentAction, CounterInteractor>(
            stateIs: \.counter,
            actionIs: \.counter,
            stateAction: \.counterStateChanged
        ) {
            CounterInteractor()
        }

        let subject = PassthroughSubject<ParentAction, Never>()
        var receivedActions: [ParentAction] = []

        await confirmation { confirmation in
            whenInteractor.interact(subject.eraseToAnyPublisher())
                .sink { action in
                    receivedActions.append(action)
                    if receivedActions.count == 3 {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.counter(.increment))
            subject.send(completion: .finished)
        }

        // Should receive: initial state (count: 0) + original action + state change (count: 1)
        #expect(receivedActions.count == 3)

        // First action should be the initial state emission
        if case .counterStateChanged(let counterState) = receivedActions[0] {
            #expect(counterState.count == 0)
        } else {
            Issue.record("Expected first action to be .counterStateChanged(count: 0)")
        }

        // Second action should be the original action passed through
        if case .counter(.increment) = receivedActions[1] {
            // Expected
        } else {
            Issue.record("Expected second action to be .counter(.increment)")
        }

        // Third action should be the state change after increment
        if case .counterStateChanged(let counterState) = receivedActions[2] {
            #expect(counterState.count == 1)
        } else {
            Issue.record("Expected third action to be .counterStateChanged(count: 1)")
        }
    }

    @Test
    func whenFiltersNonChildActions() async {
        let whenInteractor = Interactors.When<ParentState, ParentAction, CounterInteractor>(
            stateIs: \.counter,
            actionIs: \.counter,
            stateAction: \.counterStateChanged
        ) {
            CounterInteractor()
        }

        let subject = PassthroughSubject<ParentAction, Never>()
        var receivedActions: [ParentAction] = []

        await confirmation { confirmation in
            whenInteractor.interact(subject.eraseToAnyPublisher())
                .sink { action in
                    receivedActions.append(action)
                    if receivedActions.count == 3 {
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.otherAction)
            subject.send(.counterStateChanged(CounterInteractor.State(count: 42)))  // Should pass through unchanged
            subject.send(completion: .finished)
        }

        // Should receive: initial state (count: 0) + two actions we sent
        #expect(receivedActions.count == 3)

        // First action should be the initial state emission from child interactor
        if case .counterStateChanged(let counterState) = receivedActions[0] {
            #expect(counterState.count == 0)
        } else {
            Issue.record("Expected first action to be .counterStateChanged(count: 0)")
        }

        if case .otherAction = receivedActions[1] {
            // Expected
        } else {
            Issue.record("Expected second action to be .otherAction")
        }

        if case .counterStateChanged(let counterState) = receivedActions[2] {
            #expect(counterState.count == 42)
        } else {
            Issue.record("Expected third action to be .counterStateChanged(42)")
        }
    }

    @Test
    func whenMultipleChildActions() async {
        let whenInteractor = Interactors.When<ParentState, ParentAction, CounterInteractor>(
            stateIs: \.counter,
            actionIs: \.counter,
            stateAction: \.counterStateChanged
        ) {
            CounterInteractor()
        }

        let subject = PassthroughSubject<ParentAction, Never>()
        var receivedActions: [ParentAction] = []

        await confirmation { confirmation in
            whenInteractor.interact(subject.eraseToAnyPublisher())
                .sink { action in
                    receivedActions.append(action)
                    if receivedActions.count == 7 {  // initial state + 3 original + 3 state changes
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.counter(.increment))  // count: 0 -> 1
            subject.send(.counter(.increment))  // count: 1 -> 2
            subject.send(.counter(.decrement))  // count: 2 -> 1
            subject.send(completion: .finished)
        }

        #expect(receivedActions.count == 7)

        // Check that state changes reflect the progression: 0 (initial), 1, 2, 1
        let stateChangeActions = receivedActions.compactMap { action in
            if case .counterStateChanged(let state) = action {
                return state.count
            }
            return nil
        }

        #expect(stateChangeActions == [0, 1, 2, 1])
    }
}
