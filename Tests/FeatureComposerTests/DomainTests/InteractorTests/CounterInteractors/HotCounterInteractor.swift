@preconcurrency import Combine
import Foundation
@testable import FeatureComposer

struct HotCounterInteractor: Interactor {
    struct State: Equatable, Sendable {
        var count: Int
    }

    enum Action: Sendable {
        case increment
        case observe(AnyPublisher<Int, Never>)
    }
    
    var body: some InteractorOf<Self> {
        Interact<State, Action>(initialValue: State(count: 0)) { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .state
            case let .observe(publisher):
                let statePublisher = publisher
                    .map { [count = state.count] int in
                        State(count: count + int)
                    }
                return .observe(statePublisher.eraseToAnyPublisher())
            }
        }
    }
}
