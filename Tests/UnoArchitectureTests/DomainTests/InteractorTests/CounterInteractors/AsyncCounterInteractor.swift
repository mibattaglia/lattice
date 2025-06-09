import CombineSchedulers
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

    private let scheduler: AnySchedulerOf<DispatchQueue>

    init(scheduler: AnySchedulerOf<DispatchQueue>) {
        self.scheduler = scheduler
    }

    var body: some Interactor<State, Action> {
        Interact<State, Action>(initialValue: State(count: 0)) { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .state
            case .async:
                return .perform { [count = state.count] in
                    try? await scheduler.sleep(for: .seconds(0.5))
                    return AsyncCounterInteractor.DomainState(count: count + 1)
                }
            }
        }
    }
}
