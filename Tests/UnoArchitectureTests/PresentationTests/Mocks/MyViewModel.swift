import Foundation
import UnoArchitecture

@MainActor
@ViewModel<MyViewState, MyEvent>
final class MyViewModel {
    init(
        interactor: AnyInteractor<MyDomainState, MyEvent>,
        viewStateReducer: AnyViewStateReducer<MyDomainState, MyViewState>
    ) {
        self.viewState = .loading
        #subscribe { builder in
            builder
                .interactor(interactor)
                .viewStateReducer(viewStateReducer)
        }
    }
}
