import Testing

@testable import Lattice

struct CounterState: Equatable, Sendable {
    var count: Int
}

enum CounterAction: Sendable {
    case increment
    case decrement
    case reset
}

@Interactor<CounterState, CounterAction>
struct CounterInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none
            case .decrement:
                state.count -= 1
                return .none
            case .reset:
                state.count = 0
                return .none
            }
        }
    }
}
