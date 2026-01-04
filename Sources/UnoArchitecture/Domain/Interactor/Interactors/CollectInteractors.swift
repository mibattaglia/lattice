import Foundation

extension Interactors {
    /// An interactor that wraps an interactor builder result.
    ///
    /// `CollectInteractors` enables creating interactors inline using the builder syntax.
    public struct CollectInteractors<State: Sendable, Action: Sendable, Interactors: Interactor>: Interactor,
        @unchecked Sendable
    where State == Interactors.DomainState, Action == Interactors.Action {
        private let interactors: Interactors

        public init(@InteractorBuilder<State, Action> _ build: () -> Interactors) {
            self.interactors = build()
        }

        public var body: some Interactor<State, Action> { self }

        public func interact(state: inout State, action: Action) -> Emission<State> {
            interactors.interact(state: &state, action: action)
        }
    }
}
