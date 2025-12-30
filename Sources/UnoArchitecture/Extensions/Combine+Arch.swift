import Combine

//public extension Publisher where Failure == Never {
//    func interact<I: Interactor>(
//        with interactor: I
//    ) -> AnyPublisher<I.DomainState, Failure> where Output == I.Action {
//        interactor.interact(eraseToAnyPublisher())
//    }
//
//    func reduce<V: ViewStateReducer>(
//        using reducer: V
//    ) -> AnyPublisher<V.ViewState, Never> where Output == V.DomainState {
//        reducer.reduce(eraseToAnyPublisher())
//    }
//}
