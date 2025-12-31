import UnoArchitecture

/// Takes an input and doubles it
struct DoubleInteractor: Interactor {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(_ upstream: AsyncStream<Int>) -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task {
                for await value in upstream {
                    continuation.yield(value * 2)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Takes an input and triples it
struct TripleInteractor: Interactor {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(_ upstream: AsyncStream<Int>) -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task {
                for await value in upstream {
                    continuation.yield(value * 3)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
