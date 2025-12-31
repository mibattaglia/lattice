import Foundation
import SwiftUI
import UnoArchitecture

@MainActor
@ViewModel<TimelineViewState, TimelineEvent>
final class TimelineViewModel {
    init(
        interactor: AnyInteractor<TimelineDomainState, TimelineEvent>,
        viewStateReducer: AnyViewStateReducer<TimelineDomainState, TimelineViewState>
    ) {
        self.viewState = .loading
        #subscribe { builder in
            builder
                .interactor(interactor)
                .viewStateReducer(viewStateReducer)
        }
    }
}
