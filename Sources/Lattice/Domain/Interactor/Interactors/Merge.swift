extension Interactors {
    /// Combines two interactors into one, forwarding each action to both.
    ///
    /// `Merge` is used internally by ``InteractorBuilder`` when multiple interactors
    /// are listed sequentially in the `body`:
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     LoggingInteractor()
    ///     CounterInteractor()  // Merged with LoggingInteractor
    /// }
    /// ```
    ///
    /// Each action is processed by both interactors sequentially. Each child receives an
    /// effects handle with a positional `GraphPath` component appended (`.id(0)` / `.id(1)`),
    /// so effects launched by the two children never collide in the core's task storage.
    ///
    /// - Note: For merging more than two interactors, see ``MergeMany``.
    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor {
        private let i0: I0
        private let i1: I1

        /// Creates a merged interactor from two child interactors.
        ///
        /// - Parameters:
        ///   - i0: The first interactor.
        ///   - i1: The second interactor.
        public init(_ i0: I0, _ i1: I1) {
            self.i0 = i0
            self.i1 = i1
        }

        public var body: some Interactor<I0.DomainState, I0.Action> { self }

        public func interact(
            state: inout I0.DomainState,
            action: I0.Action,
            effects: Effects<I0.DomainState, I0.Action>
        ) {
            i0.interact(state: &state, action: action, effects: effects.appending(.id(0)))
            i1.interact(state: &state, action: action, effects: effects.appending(.id(1)))
        }
    }
}
