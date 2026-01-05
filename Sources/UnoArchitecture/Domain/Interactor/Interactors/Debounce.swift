import Foundation

extension Interactors {
    /// An interactor that debounces the effects of a child interactor.
    ///
    /// Actions are processed immediately through the child (state changes right away),
    /// but the child's emissions are debounced - only the last effect executes after
    /// the debounce duration elapses with no new actions.
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
    /// 2. Child's emission is debounced
    /// 3. Another action arrives → new emission cancels previous pending effect
    /// 4. After quiet period → last effect executes
    ///
    /// - Note: State changes happen immediately. Only effects are debounced.
    public struct Debounce<C: Clock, Child: Interactor & Sendable>: Interactor, Sendable
    where Child.DomainState: Sendable, Child.Action: Sendable, C.Duration: Sendable {
        public typealias DomainState = Child.DomainState
        public typealias Action = Child.Action

        private let child: Child
        private let debouncer: Debouncer<C, Action?>

        /// Creates a debouncing interactor.
        ///
        /// - Parameters:
        ///   - duration: How long to wait after the last action before executing effects.
        ///   - clock: The clock to use for timing. Inject `TestClock` for testing.
        ///   - child: A closure that returns the child interactor to wrap.
        public init(for duration: C.Duration, clock: C, child: () -> Child) {
            self.child = child()
            self.debouncer = Debouncer(for: duration, clock: clock)
        }

        public var body: some InteractorOf<Self> { self }

        public func interact(state: inout DomainState, action: Action) -> Emission<Action> {
            // Process child actions immediately
            child.interact(state: &state, action: action)
                // Emissions are debounced
                .debounce(using: debouncer)
        }
    }
}

extension Interactors.Debounce where C == ContinuousClock {
    /// Creates a debouncing interactor using the continuous clock.
    ///
    /// - Parameters:
    ///   - duration: How long to wait after the last action before executing effects.
    ///   - child: A closure that returns the child interactor to wrap.
    public init(for duration: Duration, child: () -> Child) {
        self.init(for: duration, clock: ContinuousClock(), child: child)
    }
}

public typealias DebounceInteractor<C: Clock & Sendable, Child: Interactor & Sendable> = Interactors.Debounce<C, Child>
    where Child.DomainState: Sendable, Child.Action: Sendable, C.Duration: Sendable
