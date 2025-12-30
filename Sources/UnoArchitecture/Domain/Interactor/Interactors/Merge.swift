extension Interactors {
    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor, @unchecked Sendable
    where I0.DomainState: Sendable, I0.Action: Sendable {
        private let i0: I0
        private let i1: I1

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
