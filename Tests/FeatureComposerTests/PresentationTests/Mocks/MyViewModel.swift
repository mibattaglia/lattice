import Combine
import CombineSchedulers
import Foundation

@testable import FeatureComposer

final class MyViewModel: ViewModel {
    @Published private(set) var viewState: MyViewState = .loading
    private let viewEvents = PassthroughSubject<MyEvent, Never>()

    init(
        scheduler: AnySchedulerOf<DispatchQueue>,
        interactor: AnyInteractor<MyDomainState, MyEvent>,
        viewStateReducer: AnyViewStateReducer<MyDomainState, MyViewState>
    ) {
        viewEvents
            .interact(with: interactor)
            .reduce(using: viewStateReducer)
            .receive(on: scheduler)
            .assign(to: &$viewState)
    }

    func sendViewEvent(_ event: MyEvent) {
        viewEvents.send(event)
    }
}
