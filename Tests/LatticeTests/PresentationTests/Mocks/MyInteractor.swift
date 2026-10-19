import Foundation
import Lattice

enum MyEvent: Equatable {
    case load
    case incrementCount
    case fetchData
}

@Interactor<MyScreenState, MyEvent>
struct MyInteractor: Interactor {
    let dateFactory: @Sendable () -> Date

    var body: some InteractorOf<Self> {
        Interact { state, event, effects in
            switch event {
            case .incrementCount:
                state.modify(\.success) { content in
                    content.count += 1
                    content.timestamp = dateFactory().timeIntervalSince1970
                }
            case .load:
                state = .success(
                    MyContentState(
                        count: 0,
                        timestamp: dateFactory().timeIntervalSince1970,
                        isLoading: false
                    )
                )

            case .fetchData:
                state.modify(\.success) { content in
                    content.isLoading = true
                }
                effects.perform {
                    await Task.yield()
                    try effects.modify { state in
                        state.modify(\.success) { content in
                            content.isLoading = false
                            content.count = 42
                        }
                    }
                }
            }
        }
    }
}
