@preconcurrency import Combine
import Foundation

@testable import Lattice

struct HotCounterInteractor: Interactor {
    @FeatureState
    struct State: Equatable, Sendable {
        var count: Int
    }

    enum Action: Sendable {
        case increment
        case addValue(Int)
        case observe(AnyPublisher<Int, Never>)
    }

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .increment:
                state.count += 1
            case .addValue(let value):
                state.count += value
            case .observe(let publisher):
                effects.perform {
                    for await value in publisher.values {
                        try effects.send(.addValue(value))
                    }
                }
            }
        }
    }
}
