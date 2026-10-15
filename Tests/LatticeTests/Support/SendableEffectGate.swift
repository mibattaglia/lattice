import Foundation

/// A suspension point the test opens, for effects that run off the test's isolation.
///
/// Under `TestModel` an effect waits on the model's executor while the nonisolated test opens the
/// gate, so the gate is locked (``EffectGate`` serves main-actor tests). Unlike `EffectGate.pass()`,
/// ``pass()`` also ends when the effect is cancelled: `skipInFlightEffects` and auto-cancel end
/// the wait without the test opening the gate. ``wait()`` ignores cancellation.
///
/// Both are `nonisolated(nonsending)`, so the waiter is registered on the effect's isolation
/// before the effect suspends: a cancel or an `open()` that comes after `send` returned finds it.
final class SendableEffectGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    /// Waits until ``open()`` (at once if it is already open), ignoring cancellation.
    nonisolated(nonsending) func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumesNow = lock.withLock {
                guard !isOpen else { return true }
                nextWaiterID += 1
                waiters[nextWaiterID] = continuation
                return false
            }
            if resumesNow {
                continuation.resume()
            }
        }
    }

    /// Waits until ``open()`` (at once if it is already open) or until the effect is cancelled,
    /// then throws `CancellationError` if it was: a cancellation-aware suspension point whose end
    /// the test controls.
    nonisolated(nonsending) func pass() async throws {
        let id = lock.withLock {
            nextWaiterID += 1
            return nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumesNow = lock.withLock {
                    guard !isOpen, !Task.isCancelled else { return true }
                    waiters[id] = continuation
                    return false
                }
                if resumesNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume()
        }
        try Task.checkCancellation()
    }

    /// Opens the gate: every waiting effect resumes, and later ``pass()`` calls do not wait.
    func open() {
        let waiting = lock.withLock {
            isOpen = true
            let waiting = Array(waiters.values)
            waiters.removeAll()
            return waiting
        }
        for waiter in waiting {
            waiter.resume()
        }
    }
}
