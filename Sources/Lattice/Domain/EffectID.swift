/// A type that identifies an effect launched via ``Effects/perform(id:_:fileID:filePath:line:column:)``.
///
/// Declare one as a property of your interactor and pass it to `perform` to gain an explicit
/// handle on the launched task:
///
/// ```swift
/// struct RecorderInteractor: Interactor {
///     @EffectID var recording
///
///     var body: some InteractorOf<Self> {
///         Interact { state, action, effects in
///             switch action {
///             case .startTapped:
///                 effects.perform(id: recording) { effectState in
///                     for await level in recorder.levels {
///                         try effectState.modify { $0.level = level }
///                     }
///                 }
///             case .stopTapped:
///                 effects.perform { _ in recording.cancel() }
///             }
///         }
///     }
/// }
/// ```
///
/// Because the interactor tree is built once and never remounted, the identity is stable for
/// the lifetime of the feature. The same `EffectID` can be attached to several concurrent tasks;
/// ``isRunning``, ``cancel(fileID:filePath:line:column:)`` and ``callAsFunction()`` cover all of
/// them.
@propertyWrapper
public struct EffectID {
    /// A human-readable name, used in diagnostics. Defaults to `nil`.
    public private(set) var name: String?

    let storage = Storage()

    /// The identity itself; `@EffectID var refresh` reads as `refresh`.
    public var wrappedValue: Self { self }

    /// The error thrown by the most recently completed task attached to this identity, if any.
    ///
    /// `CancellationError` is not recorded — cancellation is an expected outcome, not a
    /// failure. Cleared when a subsequent attached task completes successfully.
    public var taskError: (any Error)? {
        storage.error
    }

    /// Whether any task attached to this identity is currently running.
    ///
    /// Becomes `true` when the effect launches — synchronously, before the `send` that
    /// triggered the update returns — and `false` when the last attached task finishes or is
    /// cancelled. Intended for interactor and effect logic (e.g. "don't start a second
    /// refresh"); views should derive spinners from projected state, not from this flag.
    public var isRunning: Bool {
        storage.hasTasks()
    }

    /// Creates an effect identity.
    ///
    /// - Parameter name: An optional human-readable name used in diagnostics.
    public init(name: String? = nil) {
        self.name = name
    }

    /// Awaits every task currently attached to this identity, then rethrows the recorded
    /// ``taskError`` if one was set.
    ///
    /// ```swift
    /// effects.perform { effectState in
    ///     try await recording()          // wait for the recording effect to finish
    ///     try effectState.modify { $0.phase = .done }
    /// }
    /// ```
    public func callAsFunction() async throws {
        for task in storage.currentTasks() {
            await task.value
        }
        if let error = storage.error {
            throw error
        }
    }

    /// Cancels every task currently attached to this identity.
    ///
    /// Must be called from the effect phase. Calling it synchronously from an interactor's
    /// update phase is reported as an issue and ignored — enqueue it instead:
    /// `effects.perform { _ in refresh.cancel() }`.
    ///
    /// - Returns: One of the cancelled tasks, so callers can await its wind-down; `nil` if
    ///   nothing was running.
    @discardableResult
    public func cancel(
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> Task<Void, Never>? {
        guard !storage.isUpdatePhase() else {
            latticeReportIssue(
                """
                Can't cancel an effect synchronously from an interactor's update phase; if you \
                need to cancel an effect, enqueue the cancellation asynchronously via \
                'effects.perform { _ in \(name ?? "effect").cancel() }'
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return nil
        }
        let tasks = storage.currentTasks()
        storage.cancelledThrough = storage.generation
        storage.cancelTasks()
        return tasks.first
    }

    // MARK: Internal generation machinery (driven by 'Effects.perform')

    /// Claims a fresh generation for one launched operation.
    func nextGeneration() -> UInt64 {
        storage.generation &+= 1
        return storage.generation
    }

    /// Records a launched operation's terminal outcome (`nil` on success; `CancellationError`
    /// recorded as `nil` — cancellation is an expected outcome, not a failure). Ignored when
    /// `cancel()` already retired the generation.
    func record(error: (any Error)?, generation: UInt64) {
        guard generation > storage.cancelledThrough else { return }
        storage.error = error is CancellationError ? nil : error
    }

    final class Storage {
        /// Bound once, by the first `perform(id:)` this identity is passed to. Each closure
        /// captures the root core weakly plus this identity's task key
        /// (`TaskKey(path:location:)` with `.id(ObjectIdentifier(self))`). Unbound — or with
        /// the core gone — the defaults are inert: idle phase, no tasks, cancel is a no-op.
        private(set) var isBound = false
        var isUpdatePhase: () -> Bool = { false }
        var hasTasks: () -> Bool = { false }
        var currentTasks: () -> [Task<Void, Never>] = { [] }
        var cancelTasks: () -> Void = {}

        /// The most recently recorded terminal error. See `record(error:generation:)`.
        var error: (any Error)?
        /// Monotonic launch counter; each launched operation records under its own generation.
        var generation: UInt64 = 0
        /// Generations at or below this were cancelled; their terminal outcome is discarded.
        var cancelledThrough: UInt64 = 0

        func bind(
            isUpdatePhase: @escaping () -> Bool,
            hasTasks: @escaping () -> Bool,
            currentTasks: @escaping () -> [Task<Void, Never>],
            cancelTasks: @escaping () -> Void
        ) {
            self.isUpdatePhase = isUpdatePhase
            self.hasTasks = hasTasks
            self.currentTasks = currentTasks
            self.cancelTasks = cancelTasks
            isBound = true
        }

        deinit {
            cancelTasks()
        }
    }
}
