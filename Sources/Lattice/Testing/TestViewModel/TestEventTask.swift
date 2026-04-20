import Clocks
import Foundation

/// A handle to the root send scope started by a single ``TestViewModel/send(_:assert:fileID:file:line:column:)`` call.
///
/// `TestEventTask` only waits for the work owned by that send scope. It does not automatically
/// consume buffered received actions.
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
    @MainActor
    public func cancel() async {
        guard let rawValue else { return }

        rawValue.cancel()
        await rawValue.cancellableValue
    }

    /// Awaits quiescence of the underlying root send scope.
    ///
    /// Buffered receives remain queued on ``TestViewModel`` after this returns.
    @MainActor
    public func finish(
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let location = TestIssueLocation(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        do {
            try await finishThrowing(timeout: duration)
        } catch let failure as TestFailure {
            reportTestFailure(
                failure,
                at: location
            )
        } catch {
            reportUnexpectedTestError(
                error,
                at: location
            )
        }
    }

    private func finishThrowing(timeout duration: Duration? = nil) async throws {
        guard let rawValue else { return }

        let timeout = duration ?? self.timeout
        await Task.megaYield()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await rawValue.cancellableValue
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CancellationError()
                }

                try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            throw TestFailure.expectedTaskToFinish(timeout: timeout)
        }
    }

    /// Whether this task has been cancelled.
    public var isCancelled: Bool {
        rawValue?.isCancelled ?? false
    }

    /// Whether this task owns any emission work.
    public var hasEffects: Bool {
        rawValue != nil
    }
}
