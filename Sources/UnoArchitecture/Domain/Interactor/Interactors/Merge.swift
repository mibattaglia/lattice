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
    /// Each action is processed by both interactors sequentially, with state
    /// emissions from each forwarded downstream.
    ///
    /// - Note: For merging more than two interactors, see ``MergeMany``.
    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor, @unchecked Sendable
    where I0.DomainState: Sendable, I0.Action: Sendable {
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

        public func interact(_ upstream: AsyncStream<I0.Action>) -> AsyncStream<I0.DomainState> {
            AsyncStream { continuation in
                let task = Task {
                    for await action in upstream {
                        let (stream0, cont0) = AsyncStream<I0.Action>.makeStream()
                        cont0.yield(action)
                        cont0.finish()
                        for await state in i0.interact(stream0) {
                            continuation.yield(state)
                        }

                        let (stream1, cont1) = AsyncStream<I0.Action>.makeStream()
                        cont1.yield(action)
                        cont1.finish()
                        for await state in i1.interact(stream1) {
                            continuation.yield(state)
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
