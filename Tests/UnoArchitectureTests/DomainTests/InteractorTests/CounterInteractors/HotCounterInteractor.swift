@preconcurrency import Combine
import Foundation

@testable import UnoArchitecture

struct HotCounterInteractor: Interactor {
    struct DomainState: Equatable, Sendable {
        var count: Int
    }

    enum Action: Sendable {
        case increment
        case addValue(Int)
        case observe(AnyPublisher<Int, Never>)
    }

    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none
            case .addValue(let value):
                state.count += value
                return .none
            case .observe(let publisher):
                return .observe {
                    AsyncStream { continuation in
                        let task = Task {
                            for await value in publisher.values {
                                continuation.yield(.addValue(value))
                            }
                            continuation.finish()
                        }
                        continuation.onTermination = { @Sendable _ in task.cancel() }
                    }
                }
            }
        }
    }
}
