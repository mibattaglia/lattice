import Foundation

@testable import UnoArchitecture

@Interactor
struct AsyncCounterInteractor {
    struct State: Equatable, Sendable {
        var count: Int
    }

    enum Action: Sendable {
        case increment
        case async
    }

    var body: some Interactor<State, Action> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .state
            case .async:
                return .perform { state, send in
                    await send(AsyncCounterInteractor.DomainState(count: state.count + 1))
                }
            }
        }
    }
}
