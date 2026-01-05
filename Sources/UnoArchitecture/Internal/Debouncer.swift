/// A utility that delays and coalesces work, executing only after a quiet period.
///
/// When `debounce` is called multiple times rapidly, only the last work closure
/// executes after the debounce duration elapses with no new calls.
///
/// ## Usage
///
/// ```swift
/// let debouncer = Debouncer<ContinuousClock, Int>(for: .milliseconds(300), clock: ContinuousClock())
///
/// // Rapid calls - only the last one executes
/// let t1 = await debouncer.debounce { 1 }  // Returns Task, will be .superseded
/// let t2 = await debouncer.debounce { 2 }  // Cancels t1, will be .superseded
/// let t3 = await debouncer.debounce { 3 }  // Cancels t2, will be .executed(3)
///
/// // Await results
/// await t1.value  // .superseded
/// await t3.value  // .executed(3) after 300ms
/// ```
public actor Debouncer<C: Clock, T: Sendable> where C.Duration: Sendable {
    private let duration: C.Duration
    private let clock: C
    private var currentGeneration: UInt64 = 0
    private var currentTask: Task<DebounceResult<T>, Never>?

    /// Creates a debouncer with the specified duration and clock.
    ///
    /// - Parameters:
    ///   - duration: How long to wait after the last call before executing.
    ///   - clock: The clock to use for timing. Inject `TestClock` for testing.
    public init(for duration: C.Duration, clock: C) {
        self.duration = duration
        self.clock = clock
    }

    /// Schedules work to execute after the debounce period.
    ///
    /// If called again before the period elapses, the previous work is cancelled
    /// and the timer resets. Only the last work closure will execute.
    ///
    /// This method does not suspend - it returns a Task immediately. The caller
    /// awaits the Task's value to get the result. This design avoids actor
    /// re-entrancy issues by keeping all state mutations synchronous.
    ///
    /// - Parameter work: The closure to execute after debouncing.
    /// - Returns: A Task that resolves to `.executed(T)` or `.superseded`.
    public func debounce(_ work: @escaping @Sendable () async -> T) -> Task<DebounceResult<T>, Never> {
        currentGeneration &+= 1
        let myGeneration = currentGeneration
        currentTask?.cancel()

        let task = Task<DebounceResult<T>, Never> { [weak self, duration, clock] in
            do {
                try await clock.sleep(for: duration)

                // Check if we're still the current generation
                guard let self else { return .superseded }
                guard await self.isCurrentGeneration(myGeneration) else { return .superseded }
                guard !Task.isCancelled else { return .superseded }

                return .executed(await work())
            } catch {
                // Sleep threw CancellationError
                return .superseded
            }
        }

        currentTask = task
        return task
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        generation == currentGeneration
    }
}

extension Debouncer where C == ContinuousClock {
    /// Creates a debouncer with the specified duration using the continuous clock.
    ///
    /// - Parameter duration: How long to wait after the last call before executing.
    public init(for duration: Duration) {
        self.init(for: duration, clock: ContinuousClock())
    }
}
