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
final class ScopeTests {
    private var cancellables: Set<AnyCancellable> = []

    @Test
    func scopeKeyPathBasicFunctionality() async {
        let scope = Interactors.Scope<ParentState, ParentAction, CounterInteractor>(
            state: \.counter,
            action: \.counter,
            stateAction: \.counterStateChanged
        ) {
            CounterInteractor()
        }

        let subject = PassthroughSubject<ParentAction, Never>()
        var receivedActions: [ParentAction] = []

        await confirmation { confirmation in
            scope.interact(subject.eraseToAnyPublisher())
                .sink { action in
                    receivedActions.append(action)
                    if receivedActions.count == 3 {  // Original action + counter state change
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.counter(.increment))
            subject.send(completion: .finished)
        }

        // Should receive: original .counter(.increment) action + .counterStateChanged(CounterInteractor.State(count: 1))
        #expect(receivedActions.count == 2)

        // First action should be the original action passed through
        if case .counter(.increment) = receivedActions[0] {
            // Expected
        } else {
            Issue.record("Expected first action to be .counter(.increment)")
        }

        // Second action should be the state change action
        if case .counterStateChanged(let counterState) = receivedActions[1] {
            #expect(counterState.count == 1)
        } else {
            Issue.record("Expected second action to be .counterStateChanged")
        }
    }

    @Test
    func scopeFiltersNonChildActions() async {
        let scope = Interactors.Scope<ParentState, ParentAction, CounterInteractor>(
            state: \.counter,
            action: \.counter,
            stateAction: \.counterStateChanged
        ) {
            CounterInteractor()
        }

        let subject = PassthroughSubject<ParentAction, Never>()
        var receivedActions: [ParentAction] = []

        await confirmation { confirmation in
            scope.interact(subject.eraseToAnyPublisher())
                .sink { action in
                    receivedActions.append(action)
                    if receivedActions.count == 2 {  // Both original actions passed through
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.otherAction)
            subject.send(.counterStateChanged(CounterInteractor.State(count: 42)))  // Should pass through unchanged
            subject.send(completion: .finished)
        }

        // Should only receive the two actions we sent (non-counter actions pass through unchanged)
        #expect(receivedActions.count == 2)

        if case .otherAction = receivedActions[0] {
            // Expected
        } else {
            Issue.record("Expected first action to be .otherAction")
        }

        if case .counterStateChanged(let counterState) = receivedActions[1] {
            #expect(counterState.count == 42)
        } else {
            Issue.record("Expected second action to be .counterStateChanged(42)")
        }
    }

    @Test
    func scopeMultipleChildActions() async {
        let scope = Interactors.Scope<ParentState, ParentAction, CounterInteractor>(
            state: \.counter,
            action: \.counter,
            stateAction: \.counterStateChanged
        ) {
            CounterInteractor()
        }

        let subject = PassthroughSubject<ParentAction, Never>()
        var receivedActions: [ParentAction] = []

        await confirmation { confirmation in
            scope.interact(subject.eraseToAnyPublisher())
                .sink { action in
                    receivedActions.append(action)
                    if receivedActions.count == 6 {  // 3 original + 3 state changes
                        confirmation()
                    }
                }
                .store(in: &cancellables)

            subject.send(.counter(.increment))  // count: 0 -> 1
            subject.send(.counter(.increment))  // count: 1 -> 2
            subject.send(.counter(.decrement))  // count: 2 -> 1
            subject.send(completion: .finished)
        }

        #expect(receivedActions.count == 6)

        // Check that state changes reflect the progression: 1, 2, 1
        let stateChangeActions = receivedActions.compactMap { action in
            if case .counterStateChanged(let state) = action {
                return state.count
            }
            return nil
        }

        #expect(stateChangeActions == [1, 2, 1])
    }
}
