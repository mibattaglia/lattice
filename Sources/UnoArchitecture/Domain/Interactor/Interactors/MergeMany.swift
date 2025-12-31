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
    /// Each action is processed by all interactors sequentially, with state
    /// emissions from each forwarded downstream.
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

        public func interact(_ upstream: AsyncStream<Element.Action>) -> AsyncStream<Element.DomainState> {
            AsyncStream { continuation in
                let task = Task {
                    for await action in upstream {
                        for interactor in interactors {
                            let (stream, cont) = AsyncStream<Element.Action>.makeStream()
                            cont.yield(action)
                            cont.finish()
                            for await state in interactor.interact(stream) {
                                continuation.yield(state)
                            }
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
