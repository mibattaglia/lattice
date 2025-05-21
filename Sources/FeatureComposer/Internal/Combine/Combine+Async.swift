import Combine
import Foundation

extension Publisher {
    func async(
        work: @escaping @Sendable () async -> Output
    ) -> Publishers.Async<Output, Failure> {
        Publishers.Async<Output, Failure>(work)
    }
}

extension Publishers {
    /// A publisher that performs a piece of asynchronous work, returns its result, then completes.
    ///
    /// Adapted from: https://stackoverflow.com/questions/78892734/getting-task-isolated-value-of-type-async-passed-as-a-strongly-trans
    struct Async<Output, Failure: Error>: Publisher, Sendable {
        private let work: @Sendable () async -> Output
        
        init(
            _ work: @escaping @Sendable () async -> Output
        ) {
            self.work = work
        }
        
        func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input, S: Sendable {
            let subscription = AsyncPublisherSubscription(
                subscriber: subscriber,
                work: work
            )
            subscriber.receive(subscription: subscription)
        }
    }
}



private extension Publishers.Async {
    final class AsyncPublisherSubscription<S: Subscriber>: Subscription, @unchecked Sendable where S.Input == Output, S.Failure == Failure, S: Sendable {
        private let lock = NSLock()
        
        private var subscriber: S?
        private var task: Task<Void, Never>?
        private var result: Output?
        private var demand: Subscribers.Demand = .none
        
        init(
            subscriber: S,
            work: @escaping @Sendable () async -> Output
        ) {
            self.subscriber = subscriber
            task = Task { [weak self] in
                let value = await work()
                self?.publisherProvided(value)
            }
        }
        
        func cancel() {
            lock.withLock {
                task?.cancel()
                task = nil
                subscriber = nil
            }
        }
        
        func request(_ demand: Subscribers.Demand) {
            subscriberRequested(demand)
        }
    }
}

private extension Publishers.Async.AsyncPublisherSubscription {
    /// Publisher has provided a result
    ///
    /// If subscriber has already requested a result, then just send it.
    /// If subscriber has not yet requested result, then just save this result for future reference.
    func publisherProvided(_ result: Output) {
        defer { lock.unlock() }
        lock.withLock {
            if demand > .none {
                sendOutputToSubscriber(result: result)
            } else {
                self.result = result
            }
        }
    }
    
    /// Subscriber has requested value
    ///
    /// If publisher has already provided a result and subscriber demand > .none, then send it.
    /// If publisher has not, just update the local demand count.
    func subscriberRequested(_ demand: Subscribers.Demand) {
        defer { lock.unlock() }
        lock.withLock {
            self.demand += demand
            if let result, self.demand > .none {
                sendOutputToSubscriber(result: result)
            }
        }
    }
    
    /// Send output to subscriber
    ///
    /// Called only when both of the following are satisfied:
    ///    * publisher has provided a result to be sent; and
    ///    * subscriber has requested demand.
    func sendOutputToSubscriber(result: Output) {
        demand -= 1
        _ = subscriber?.receive(result)
        subscriber?.receive(completion: .finished)
    }
}
