import FeatureComposer
import Foundation

enum MyEvent: Equatable {
    case load
    case incrementCount
}

struct MyInteractor: Interactor {
    typealias Action = MyEvent
    typealias DomainState = MyDomainState

    let dateFactory: () -> Date

    var body: some InteractorOf<Self> {
        Interact(initialValue: .loading) { domainState, event in
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
            }
        }
    }
}
