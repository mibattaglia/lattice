import Foundation

@testable import Lattice

@FeatureState
struct AsyncCounterState: Equatable, Sendable {
    var count: Int
}

enum AsyncCounterAction: Sendable, Equatable {
    case increment
    case asyncIncrement
}

@Interactor<AsyncCounterState, AsyncCounterAction>
struct AsyncCounterInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .increment:
                state.count += 1
            case .asyncIncrement:
                effects.perform {
                    try effects.send(.increment)
                }
            }
        }
    }
}
