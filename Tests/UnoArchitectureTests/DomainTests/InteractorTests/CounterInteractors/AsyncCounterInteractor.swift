import Foundation

@testable import UnoArchitecture

@Interactor
struct AsyncCounterInteractor {
    struct State: Equatable, Sendable {
        var count: Int
    }

    enum Action: Sendable, Equatable {
        case increment
        case asyncIncrement
    }

    var body: some Interactor<State, Action> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none
            case .asyncIncrement:
                return .perform {
                    .increment
                }
            }
        }
    }
}
