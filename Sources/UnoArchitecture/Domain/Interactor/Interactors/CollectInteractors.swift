import Foundation

extension Interactors {
    public struct CollectInteractors<State: Sendable, Action: Sendable, Interactors: Interactor>: Interactor,
        @unchecked Sendable
    where State == Interactors.DomainState, Action == Interactors.Action {
        private let interactors: Interactors

        public init(@InteractorBuilder<State, Action> _ build: () -> Interactors) {
            self.interactors = build()
        }

        public var body: some Interactor<State, Action> { self }

        public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
            interactors.interact(upstream)
        }
    }
}
