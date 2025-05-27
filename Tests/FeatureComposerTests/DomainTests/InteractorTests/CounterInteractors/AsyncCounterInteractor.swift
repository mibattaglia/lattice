import CombineSchedulers
import Foundation

@testable import FeatureComposer

struct AsyncCounterInteractor: Interactor {
    struct DomainState: Equatable, Sendable {
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

    var body: some InteractorOf<Self> {
        Interact<DomainState, Action>(initialValue: DomainState(count: 0)) { state, action in
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
