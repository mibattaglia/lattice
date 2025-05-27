import Combine
import Foundation

extension Interactors {
    public struct CollectInteractors<State, Action, Interactors: Interactor>: Interactor
    where State == Interactors.State, Action == Interactors.Action {
        private let interactors: Interactors

        public init(@InteractorBuilder<State, Action> _ build: () -> Interactors) {
            self.interactors = build()
        }

        public var body: some Interactor<State, Action> { self }

        public func interact(_ upstream: AnyPublisher<Action, Never>) -> AnyPublisher<State, Never>
        {
            interactors.interact(upstream)
        }
    }
}
