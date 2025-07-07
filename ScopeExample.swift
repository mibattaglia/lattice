import CasePaths
import Combine
import Foundation

// Import our library
// Note: This would normally be: import UnoArchitecture

// MARK: - Demo Domain Models

struct CounterState {
    var count: Int
}

struct ParentState {
    var counter: CounterState
    var name: String
}

@CasePathable
enum CounterAction {
    case increment
    case decrement
    case reset
}

@CasePathable
enum ParentAction {
    case counter(CounterAction)
    case counterStateChanged(CounterState)
    case changeName(String)
}

// MARK: - Demo Interactors

struct CounterInteractor: Interactor {
    typealias DomainState = CounterState
    typealias Action = CounterAction

    var body: some InteractorOf<Self> {
        Interact(initialValue: CounterState(count: 0)) { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .state
            case .decrement:
                state.count -= 1
                return .state
            case .reset:
                state.count = 0
                return .state
            }
        }
    }
}

struct ParentInteractor: Interactor {
    typealias DomainState = ParentState
    typealias Action = ParentAction

    var body: some InteractorOf<Self> {
        // This is where the magic happens!
        Interactors.Scope(
            state: \.counter,
            action: \.counter,
            stateAction: \.counterStateChanged
        ) {
            CounterInteractor()
        }

        Interact(initialValue: ParentState(counter: CounterState(count: 0), name: "Demo")) { state, action in
            switch action {
            case .counter:
                // Child actions are handled by Scope above
                return .state
            case .counterStateChanged(let newCounterState):
                // Update parent state with new child state
                state.counter = newCounterState
                return .state
            case .changeName(let newName):
                state.name = newName
                return .state
            }
        }
    }
}

// MARK: - Demo Usage

func runScopeDemo() {
    print("🚀 Scope Demo Starting...")

    let parentInteractor = ParentInteractor()
    let actionSubject = PassthroughSubject<ParentAction, Never>()
    var cancellables = Set<AnyCancellable>()

    // Subscribe to state changes
    actionSubject
        .interact(with: parentInteractor)
        .sink { state in
            print("📊 State Update: counter=\(state.counter.count), name='\(state.name)'")
        }
        .store(in: &cancellables)

    // Send some actions
    print("\n🔄 Sending actions...")

    actionSubject.send(.counter(.increment))  // Should increase counter to 1
    actionSubject.send(.counter(.increment))  // Should increase counter to 2
    actionSubject.send(.changeName("Updated"))  // Should change name
    actionSubject.send(.counter(.decrement))  // Should decrease counter to 1
    actionSubject.send(.counter(.reset))  // Should reset counter to 0

    // Give it a moment to process
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        actionSubject.send(completion: .finished)
        print("\n✅ Scope Demo Complete!")
    }
}

// Uncomment to run:
// runScopeDemo()
