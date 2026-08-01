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
    /// Each action is processed by all interactors sequentially. Each child receives an
    /// effects handle with its positional index appended as a `GraphPath` component (`.id(i)`).
    ///
    /// - Important: Path identity is positional. `for`-loops that build interactors from
    ///   dynamic collections must produce a stable order; reordering the collection at
    ///   runtime is unsupported (the composition tree is static).
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

        public var body: some Interactor<Element.DomainState, Element.Action> { self }

        public func interact(
            state: inout Element.DomainState,
            action: Element.Action,
            effects: Effects<Element.DomainState, Element.Action>
        ) {
            for (index, interactor) in interactors.enumerated() {
                interactor.interact(state: &state, action: action, effects: effects.appending(.id(index)))
            }
        }
    }
}
