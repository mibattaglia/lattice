import Testing

@testable import Lattice

@Interactor
struct CounterInteractor {
    struct State: Equatable, Sendable {
        var count: Int
    }

    enum Action: Sendable {
        case increment
        case decrement
        case reset
    }

    var body: some Interactor<State, Action> {
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
