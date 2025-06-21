import Combine
import CombineSchedulers
import Foundation
import UnoArchitecture
/*
@ViewModel<MyViewState, MyEvent>
final class MyViewModel_PostMacro {
    init(
        scheduler: AnySchedulerOf<DispatchQueue>,
        interactor: AnyInteractor<MyDomainState, MyEvent>,
        viewStateReducer: AnyViewStateReducer<MyDomainState, MyViewState>
    ) {
        self.viewState = .loading
        #subscribe(scheduler, interactor, viewStateReducer)
    }
}
*/
