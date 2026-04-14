import Foundation

/// A handle to the root send scope started by a single ``TestViewModel/send(_:assert:fileID:file:line:column:)`` call.
public struct TestEventTask: Sendable {
    internal let rawValue: Task<Void, Never>?
    internal let timeout: Duration

    init(
        rawValue: Task<Void, Never>?,
        timeout: Duration
    ) {
        self.rawValue = rawValue
        self.timeout = timeout
    }

    /// Cancels the underlying root send scope and waits for cancellation to settle.
    public func cancel() async {
        rawValue?.cancel()
        await rawValue?.value
    }

    /// Awaits quiescence of the underlying root send scope.
    public func finish(timeout duration: Duration? = nil) async throws {
        guard let rawValue else { return }

        let timeout = duration ?? self.timeout

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await rawValue.value
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestFailure.expectedTaskToFinish(timeout: timeout)
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// Whether this task has been cancelled.
    public var isCancelled: Bool {
        rawValue?.isCancelled ?? false
    }

    /// Whether this task owns any effect work.
    public var hasEffects: Bool {
        rawValue != nil
    }
}
