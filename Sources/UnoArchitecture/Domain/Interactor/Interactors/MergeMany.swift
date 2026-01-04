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
    /// Each action is processed by all interactors sequentially, with their
    /// emissions merged together.
    ///
    /// - Note: For merging exactly two interactors, see ``Merge``.
    public struct MergeMany<Element: Interactor>: Interactor, @unchecked Sendable
    where Element.DomainState: Sendable, Element.Action: Sendable {
        private let interactors: [Element]

        /// Creates a merged interactor from an array of child interactors.
        ///
        /// - Parameter interactors: The interactors to merge.
        public init(interactors: [Element]) {
            self.interactors = interactors
        }

        public var body: some Interactor<Element.DomainState, Element.Action> { self }

        public func interact(state: inout Element.DomainState, action: Element.Action) -> Emission<Element.DomainState> {
            let emissions = interactors.map { interactor in
                interactor.interact(state: &state, action: action)
            }
            return .merge(emissions)
        }
    }
}
