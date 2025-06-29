import Combine
import CombineSchedulers
import Foundation
import UnoArchitecture

@ViewModel<MyViewState, MyEvent>
final class MyViewModel {
    init(
        scheduler: AnySchedulerOf<DispatchQueue>,
        interactor: AnyInteractor<MyDomainState, MyEvent>,
        viewStateReducer: AnyViewStateReducer<MyDomainState, MyViewState>
    ) {
        self.viewState = .loading
        #subscribe { builder in
            builder
                .viewStateReceiver(scheduler)
                .interactor(interactor)
                .viewStateReducer(viewStateReducer)
        }
    }
}
