import Combine
import CombineSchedulers
import Foundation
import SwiftUI
import UnoArchitecture

@MainActor
@ViewModel<SearchViewState, SearchEvent>
final class SearchViewModel {
    init(
        interactor: AnyInteractor<SearchDomainState, SearchEvent>,
        viewStateReducer: AnyViewStateReducer<SearchDomainState, SearchViewState>
    ) {
        self.viewState = .none
        #subscribe { builder in
            builder
                .interactor(interactor)
                .viewStateReducer(viewStateReducer)
        }
    }
}
