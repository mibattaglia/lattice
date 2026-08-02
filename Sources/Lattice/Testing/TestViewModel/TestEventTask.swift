import Foundation

/// A handle to the effects launched directly by a single
/// ``TestViewModel/send(_:changes:fileID:file:line:column:)`` call.
///
/// A thin wrapper over the composite task the core's `send` returns (`EventTask`
/// semantics: the send's directly launched effects). Waiting is a plain race against a
/// timeout — commits are recorded synchronously by the funnel and effects start in-domain
/// before `send` returns, so there is nothing to yield for.
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

    /// Cancels the send's directly launched effects and waits for them to wind down.
    @MainActor
    public func cancel() async {
        guard let rawValue else { return }

        rawValue.cancel()
        await rawValue.value
    }

    /// Awaits completion of the send's directly launched effects.
    ///
    /// Reports ``TestFailure/expectedTaskToFinish(timeout:)`` — and cancels the still-running
    /// effects so the test can proceed — if they do not complete within the timeout.
    @MainActor
    public func finish(
        timeout duration: Duration? = nil,
        fileID: StaticString = #fileID,
        file filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        guard let rawValue else { return }

        let timeout = duration ?? self.timeout
        let finished = await raceAgainstTimeout(timeout) {
            await rawValue.cancellableValue
        }
        if !finished {
            reportTestFailure(
                .expectedTaskToFinish(timeout: timeout),
                at: TestIssueLocation(
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            )
        }
    }

    /// Whether this task has been cancelled.
    public var isCancelled: Bool {
        rawValue?.isCancelled ?? false
    }

    /// Whether this send launched any effects directly.
    public var hasEffects: Bool {
        rawValue != nil
    }
}

// MARK: - Waiting primitives (shared with TestViewModel)

extension Task where Failure == Never {
    /// Awaits the task's value, propagating cancellation of the awaiting context into the
    /// task itself (a bare `Task.value` on a non-throwing task ignores cancellation).
    var cancellableValue: Success {
        get async {
            await withTaskCancellationHandler {
                await value
            } onCancel: {
                cancel()
            }
        }
    }
}

/// Races `operation` against a timeout. Returns `false` on timeout, cancelling the operation's
/// child task (which propagates into awaited tasks via `cancellableValue`).
func raceAgainstTimeout(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await operation()
            return true
        }
        group.addTask {
            do {
                try await Task.sleep(for: timeout)
                return false
            } catch {
                // Cancelled: the operation won the race.
                return true
            }
        }
        let winner = await group.next() ?? true
        group.cancelAll()
        return winner
    }
}
