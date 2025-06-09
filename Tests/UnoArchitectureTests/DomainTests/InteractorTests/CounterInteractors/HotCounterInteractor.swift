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
        Interact<DomainState, Action>(initialValue: DomainState(count: 0)) { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .state
            case let .observe(publisher):
                return .observe { state in
                    let statePublisher =
                        publisher
                        .map { int in
                            DomainState(count: state.count + int)
                        }
                    return statePublisher.eraseToAnyPublisher()
                }
            }
        }
    }
}
