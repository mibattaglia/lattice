import Foundation
import Lattice

enum MyEvent: Equatable {
    case load
    case incrementCount
    case fetchData
    case fetchDataCompleted(Int)
}

@Interactor<MyScreenState, MyEvent>
struct MyInteractor: Interactor {
    let dateFactory: @Sendable () -> Date

    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .incrementCount:
                state.modify(\.success) { content in
                    content.count += 1
                    content.timestamp = dateFactory().timeIntervalSince1970
                }
                return .none
            case .load:
                state = .success(
                    MyContentState(
                        count: 0,
                        timestamp: dateFactory().timeIntervalSince1970,
                        isLoading: false
                    )
                )
                return .none

            case .fetchData:
                state.modify(\.success) { content in
                    content.isLoading = true
                }
                return .perform {
                    try? await Task.sleep(for: .milliseconds(10))
                    return .fetchDataCompleted(42)
                }

            case .fetchDataCompleted(let count):
                state.modify(\.success) { content in
                    content.isLoading = false
                    content.count = count
                }
                return .none
            }
        }
    }
}
