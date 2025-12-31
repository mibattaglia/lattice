import AsyncAlgorithms
import Foundation

extension Interactors {
    /// An interactor that debounces actions before forwarding them to a child interactor.
    ///
    /// `Debounce` delays forwarding actions until a specified time has passed without
    /// receiving new actions. This is useful for scenarios like search-as-you-type,
    /// where you want to wait for the user to stop typing before making a request.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     DebounceInteractor(for: .milliseconds(300)) {
    ///         SearchInteractor()
    ///     }
    /// }
    /// ```
    ///
    /// ## Testing
    ///
    /// Inject a `TestClock` for deterministic time control in tests:
    ///
    /// ```swift
    /// let clock = TestClock()
    /// let interactor = DebounceInteractor(for: .seconds(1), clock: clock) {
    ///     SearchInteractor()
    /// }
    /// // Advance time manually with clock.advance(by:)
    /// ```
    ///
    /// - Note: Uses `swift-async-algorithms` debounce operator internally.
    public struct Debounce<C: Clock, Child: Interactor & Sendable>: Interactor, Sendable
    where Child.DomainState: Sendable, Child.Action: Sendable, C.Duration: Sendable {
        public typealias DomainState = Child.DomainState
        public typealias Action = Child.Action

        private let child: Child
        private let duration: C.Duration
        private let clock: C

        /// Creates a debouncing interactor with a custom clock.
        ///
        /// - Parameters:
        ///   - duration: The time to wait after the last action before forwarding.
        ///   - clock: The clock to use for timing. Inject `TestClock` for testing.
        ///   - child: A closure that returns the child interactor to wrap.
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
    /// Creates a debouncing interactor using the system clock.
    ///
    /// - Parameters:
    ///   - duration: The time to wait after the last action before forwarding.
    ///   - child: A closure that returns the child interactor to wrap.
    public init(for duration: Duration, child: () -> Child) {
        self.init(for: duration, clock: ContinuousClock(), child: child)
    }
}

/// A convenience typealias for ``Interactors/Debounce``.
///
/// Usage:
/// ```swift
/// DebounceInteractor(for: .milliseconds(300)) {
///     SearchInteractor()
/// }
/// ```
public typealias DebounceInteractor<C: Clock & Sendable, Child: Interactor & Sendable> = Interactors.Debounce<C, Child>
