import Combine
import CombineSchedulers
import Foundation
import SwiftUI
import UnoArchitecture

@ViewModel<SearchViewState, SearchEvent>
final class SearchViewModel {
    init(
        scheduler: AnySchedulerOf<DispatchQueue> = .main,
        interactor: AnyInteractor<SearchDomainState, SearchEvent>,
        viewStateReducer: AnyViewStateReducer<SearchDomainState, SearchViewState>
    ) {
        self.viewState = .none
        #subscribe { builder in
            builder
                .interactor(interactor)
                .viewStateReducer(viewStateReducer)
                .viewStateReceiver(scheduler)
        }
    }
}
