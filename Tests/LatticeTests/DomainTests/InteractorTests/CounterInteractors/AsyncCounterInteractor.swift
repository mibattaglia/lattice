import Foundation

@testable import Lattice

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
