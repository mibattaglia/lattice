/// A utility that delays and coalesces work, executing only after a quiet period.
///
/// When `debounce` is called multiple times rapidly, only the last work closure
/// executes after the debounce duration elapses with no new calls.
///
/// ## Usage
///
/// ```swift
/// let debouncer = Debouncer(for: .milliseconds(300), clock: ContinuousClock())
///
/// // Rapid calls - only the last one executes
/// await debouncer.debounce { print("first") }   // cancelled
/// await debouncer.debounce { print("second") }  // cancelled
/// await debouncer.debounce { print("third") }   // executes after 300ms
/// ```
public actor Debouncer<C: Clock> where C.Duration: Sendable {
    private let duration: C.Duration
    private let clock: C
    private var currentTask: Task<Void, Never>?

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
    /// - Parameter work: The closure to execute after debouncing.
    /// - Returns: A task that completes when this debounce attempt finishes
    ///   (either by executing or being superseded).
    @discardableResult
    public func debounce(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        currentTask?.cancel()

        let task = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.clock.sleep(for: self.duration)
                guard !Task.isCancelled else { return }
                await work()
            } catch {
                // Sleep threw CancellationError - don't execute
            }
        }

        currentTask = task
        return task
    }
}
