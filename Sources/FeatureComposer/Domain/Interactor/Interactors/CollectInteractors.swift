import Combine
import Foundation

public extension Interactors {
    struct CollectInteractors<State, Action, Content: Interactor>: Interactor
    where State == Content.State, Action == Content.Action {
        private let interactors: Content
        
        public init(@InteractorBuilder<State, Action> _ build: () -> Content) {
            self.interactors = build()
        }
        
        public var body: some Interactor<State, Action> { self }
        
        public func interact(_ upstream: AnyPublisher<Action, Never>) -> AnyPublisher<State, Never> {
            interactors.interact(upstream)
        }
    }
}
