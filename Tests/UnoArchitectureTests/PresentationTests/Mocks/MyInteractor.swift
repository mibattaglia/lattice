import Foundation
import UnoArchitecture

enum MyEvent: Equatable {
    case load
    case incrementCount
    case fetchData
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
                return .state
            case .load:
                domainState = MyDomainState.success(
                    .init(
                        count: 0,
                        timestamp: dateFactory().timeIntervalSince1970,
                        isLoading: false
                    )
                )
                return .state

            case .fetchData:
                domainState.modify(\.success) { content in
                    content.isLoading = true
                }
                return .perform { state, send in
                    try? await Task.sleep(for: .milliseconds(10))
                    var current = await state.current
                    current.modify(\.success) { content in
                        content.isLoading = false
                        content.count = 42
                    }
                    await send(current)
                }
            }
        }
    }
}
