import Foundation

extension Interactors {
    /// Delays every effect the child performs by `duration`. Re-handling the action case cancels
    /// the previous delayed effects, so rapid repeats coalesce to the last one.
    ///
    /// Actions are processed immediately through the child (state changes right away); only the
    /// effects the child performs wait out the quiet period.
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///     Interactors.Debounce(for: .milliseconds(300)) {
    ///         SearchInteractor()
    ///     }
    /// }
    /// ```
    ///
    /// ## Behavior
    ///
    /// 1. Action arrives → processed immediately, state changes
    /// 2. Each effect the child performs first sleeps for `duration` on `clock`
    /// 3. The same action case arrives again → the previous sleeping effect is auto-cancelled
    /// 4. After the quiet period → the last effect runs
    ///
    /// `Debounce` holds no per-instance state, so it behaves the same whether it is stored or built
    /// inside `body` on every action. Effects performed with an `@EffectID` key are delayed too;
    /// they are replaced per key instead of auto-cancelled.
    public struct Debounce<C: Clock, Child: Interactor>: Interactor {
        public typealias State = Child.State
        public typealias Action = Child.Action

        private let duration: C.Duration
        private let clock: C
        private let child: Child

        /// Creates a debouncing interactor.
        ///
        /// - Parameters:
        ///   - duration: How long each effect waits before it runs.
        ///   - clock: The clock to use for timing. Tests inject a clock they control and wait for
        ///     the sleep to register before moving time: `TestClock.advance` right after a send
        ///     races the sleep's registration.
        ///   - child: A closure that returns the child interactor to wrap.
        public init(for duration: C.Duration, clock: C, child: () -> Child) {
            self.duration = duration
            self.clock = clock
            self.child = child()
        }

        public var body: some InteractorOf<Self> { self }

        public func interact(
            state: inout Child.State,
            action: Child.Action,
            effects: Effects<Child.State, Child.Action>
        ) {
            let clock = clock
            let duration = duration
            child.interact(
                state: &state,
                action: action,
                effects: effects.transformingOperations { operation in
                    {
                        try await clock.sleep(for: duration)
                        try await operation()
                    }
                }
            )
        }
    }
}

extension Interactors.Debounce where C == ContinuousClock {
    /// Creates a debouncing interactor using the continuous clock.
    ///
    /// - Parameters:
    ///   - duration: How long each effect waits before it runs.
    ///   - child: A closure that returns the child interactor to wrap.
    public init(for duration: Duration, child: () -> Child) {
        self.init(for: duration, clock: ContinuousClock(), child: child)
    }
}

public typealias DebounceInteractor<C: Clock, Child: Interactor> = Interactors.Debounce<C, Child>
