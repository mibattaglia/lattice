import Foundation

extension Interactors {
    /// An interactor that wraps an interactor builder result.
    ///
    /// `CollectInteractors` enables creating interactors inline using the builder syntax.
    /// It is structurally transparent: it forwards the effects handle unmodified.
    public struct CollectInteractors<State, Action, Interactors: Interactor>: Interactor
    where State == Interactors.DomainState, Action == Interactors.Action {
        private let interactors: Interactors

        public init(@InteractorBuilder<State, Action> _ build: () -> Interactors) {
            self.interactors = build()
        }

        public var body: some Interactor<State, Action> { self }

        /// Structurally transparent: forwards the effects handle unmodified; the builder
        /// result it wraps appends its own positional components.
        public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
            interactors.interact(state: &state, action: action, effects: effects)
        }
    }
}
