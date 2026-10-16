import Foundation

/// A dependency stub: a stored continuation the test opens, standing in for a slow dependency's answer.
/// `wait()` ignores cancellation, so a stale answer still reaches the feature's `try Task.checkCancellation()`.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var nextWaiterID = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Waits until ``open()``, ignoring cancellation. `nonisolated(nonsending)`, as ``pass()`` is: the
    /// waiter is registered on the effect's isolation before the effect suspends, so an `open()` or a
    /// cancel that comes after `send` returned finds it.
    nonisolated(nonsending) func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumesNow = lock.withLock {
                guard !isOpen else { return true }
                nextWaiterID += 1
                waiters.append((nextWaiterID, continuation))
                return false
            }
            if resumesNow {
                continuation.resume()
            }
        }
    }

    /// Waits until ``open()`` or until the effect is cancelled, then throws `CancellationError` if it
    /// was.
    nonisolated(nonsending) func pass() async throws {
        let id = lock.withLock {
            nextWaiterID += 1
            return nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumesNow = lock.withLock {
                    guard !isOpen, !Task.isCancelled else { return true }
                    waiters.append((id, continuation))
                    return false
                }
                if resumesNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }?.resume()
        }
        try Task.checkCancellation()
    }

    /// Opens the gate, from any isolation: the waiting effects resume in the order they arrived, and
    /// later waits do not wait.
    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters.map(\.continuation)
        }
        for continuation in waiting {
            continuation.resume()
        }
    }
}
