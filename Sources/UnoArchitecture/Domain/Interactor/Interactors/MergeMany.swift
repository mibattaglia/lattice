extension Interactors {
    public struct MergeMany<Element: Interactor>: Interactor, @unchecked Sendable
    where Element.DomainState: Sendable, Element.Action: Sendable {
        private let interactors: [Element]

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
