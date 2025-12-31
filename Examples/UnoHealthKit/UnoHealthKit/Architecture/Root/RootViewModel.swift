import Foundation
import SwiftUI
import UnoArchitecture

@MainActor
@ViewModel<RootViewState, RootEvent>
final class RootViewModel {
    init(
        interactor: AnyInteractor<RootDomainState, RootEvent>,
        viewStateReducer: AnyViewStateReducer<RootDomainState, RootViewState>
    ) {
        self.viewState = .loading
        #subscribe { builder in
            builder
                .interactor(interactor)
                .viewStateReducer(viewStateReducer)
        }
    }
}
