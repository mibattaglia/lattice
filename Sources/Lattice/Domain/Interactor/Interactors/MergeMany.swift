extension Interactors {
    /// Combines an array of interactors into one, forwarding each action to all.
    ///
    /// `MergeMany` is used internally by ``InteractorBuilder`` when interactors are
    /// provided via array syntax or variadic parameters:
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     // Array literal
    ///     [LoggingInteractor(), AnalyticsInteractor()]
    ///
    ///     // Or via buildArray
    ///     for feature in features {
    ///         FeatureInteractor(feature: feature)
    ///     }
    /// }
    /// ```
    ///
    /// Each action is processed by all interactors sequentially, in order, with the same
    /// ``Effects`` handle; their effects start in that order.
    ///
    /// - Note: For merging exactly two interactors, see ``Merge``.
    public struct MergeMany<Element: Interactor>: Interactor {
        private let interactors: [Element]

        /// Creates a merged interactor from an array of child interactors.
        ///
        /// - Parameter interactors: The interactors to merge.
        public init(interactors: [Element]) {
            self.interactors = interactors
        }

        public var body: some Interactor<Element.State, Element.Action> { self }

        public func interact(
            state: inout Element.State,
            action: Element.Action,
            effects: Effects<Element.State, Element.Action>
        ) {
            for interactor in interactors {
                interactor.interact(state: &state, action: action, effects: effects)
            }
        }
    }
}
