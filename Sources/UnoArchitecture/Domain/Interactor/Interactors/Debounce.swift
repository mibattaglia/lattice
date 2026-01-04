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
    public struct Debounce<C: Clock, Child: Interactor & Sendable>: Interactor, @unchecked Sendable
    where Child.DomainState: Sendable, Child.Action: Sendable, C.Duration: Sendable {
        public typealias DomainState = Child.DomainState
        public typealias Action = Child.Action

        private let child: Child
        private let debouncer: Debouncer<C>

        /// Creates a debouncing interactor with a custom clock.
        ///
        /// - Parameters:
        ///   - duration: The time to wait after the last action before forwarding.
        ///   - clock: The clock to use for timing. Inject `TestClock` for testing.
        ///   - child: A closure that returns the child interactor to wrap.
        public init(for duration: C.Duration, clock: C, child: () -> Child) {
            self.child = child()
            self.debouncer = Debouncer(for: duration, clock: clock)
        }

        public var body: some InteractorOf<Self> { self }

        public func interact(state: inout DomainState, action: Action) -> Emission<DomainState> {
            let capturedChild = child
            let capturedDebouncer = debouncer
            let capturedAction = action

            return .observe { dynamicState, send in
                await capturedDebouncer.debounce {
                    // Execute child emissions recursively
                    func executeChildEmission(_ emission: Emission<DomainState>) async {
                        switch emission.kind {
                        case .state:
                            break
                        case .perform(let work):
                            await work(dynamicState, send)
                        case .observe(let stream):
                            await stream(dynamicState, send)
                        case .merge(let emissions):
                            await withTaskGroup(of: Void.self) { group in
                                for childEmission in emissions {
                                    group.addTask { await executeChildEmission(childEmission) }
                                }
                            }
                        }
                    }

                    // Get current state and apply child's interaction
                    var currentState = await dynamicState.current
                    let childEmission = capturedChild.interact(state: &currentState, action: capturedAction)

                    // Send the synchronous state mutation
                    await send(currentState)

                    // Execute the child's async work (if any)
                    await executeChildEmission(childEmission)
                }
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
