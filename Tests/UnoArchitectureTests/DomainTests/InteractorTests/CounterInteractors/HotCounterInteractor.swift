@preconcurrency import Combine
import Foundation

@testable import UnoArchitecture

struct HotCounterInteractor: Interactor {
    struct DomainState: Equatable, Sendable {
        var count: Int
    }

    enum Action: Sendable {
        case increment
        case observe(AnyPublisher<Int, Never>)
    }

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .state
            case .observe(let publisher):
                return .observe { state, send in
                    let stateStream = publisher.values
                    for await value in stateStream {
                        await send(DomainState(count: state.count + value))
                    }
                }
            }
        }
    }
}
