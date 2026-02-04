import Foundation
import Lattice

enum MyEvent: Equatable {
    case load
    case incrementCount
    case fetchData
    case fetchDataCompleted(Int)
}

@Interactor<MyDomainState, MyEvent>
struct MyInteractor: Interactor {
    let dateFactory: @Sendable () -> Date

    var body: some InteractorOf<Self> {
        Interact { domainState, event in
            switch event {
            case .incrementCount:
                domainState.modify(\.success) { content in
                    content.count += 1
                    content.timestamp = dateFactory().timeIntervalSince1970
                }
                return .none
            case .load:
                domainState = MyDomainState.success(
                    .init(
                        count: 0,
                        timestamp: dateFactory().timeIntervalSince1970,
                        isLoading: false
                    )
                )
                return .none

            case .fetchData:
                domainState.modify(\.success) { content in
                    content.isLoading = true
                }
                return .perform {
                    try? await Task.sleep(for: .milliseconds(10))
                    return .fetchDataCompleted(42)
                }

            case .fetchDataCompleted(let count):
                domainState.modify(\.success) { content in
                    content.isLoading = false
                    content.count = count
                }
                return .none
            }
        }
    }
}
