import AsyncAlgorithms
import Foundation

extension Interactors {
    public struct Debounce<C: Clock, Child: Interactor & Sendable>: Interactor, Sendable
    where Child.DomainState: Sendable, Child.Action: Sendable, C.Duration: Sendable {
        public typealias DomainState = Child.DomainState
        public typealias Action = Child.Action

        private let child: Child
        private let duration: C.Duration
        private let clock: C

        public init(for duration: C.Duration, clock: C, child: () -> Child) {
            self.duration = duration
            self.clock = clock
            self.child = child()
        }

        public var body: some InteractorOf<Self> { self }

        public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState> {
            AsyncStream { continuation in
                let task = Task {
                    let debouncedActions = upstream.debounce(for: duration, clock: clock)
                    let (childStream, childCont) = AsyncStream<Action>.makeStream()

                    let forwardTask = Task {
                        for try await action in debouncedActions {
                            childCont.yield(action)
                        }
                        childCont.finish()
                    }

                    for await state in child.interact(childStream) {
                        continuation.yield(state)
                    }

                    forwardTask.cancel()
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}

extension Interactors.Debounce where C == ContinuousClock {
    public init(for duration: Duration, child: () -> Child) {
        self.init(for: duration, clock: ContinuousClock(), child: child)
    }
}

public typealias DebounceInteractor<C: Clock & Sendable, Child: Interactor & Sendable> = Interactors.Debounce<C, Child>
