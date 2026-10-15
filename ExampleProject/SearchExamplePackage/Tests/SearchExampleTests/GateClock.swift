import Foundation

/// A clock whose time moves only when the test moves it, and only after the test has seen the
/// sleeps it means to end.
///
/// `TestClock.advance` right after a send races the sleep it should end: `Clock.sleep` is
/// `@concurrent`, so an effect registers its sleep only after it has hopped off the model's
/// executor, and `advance` can look for sleepers before that. Here the test first awaits the
/// registration with ``waitForSleepers(_:)``, then moves time with ``moveForward(by:)``, which
/// wakes every sleep it reaches before it returns.
///
/// Sleeps are cancellation-aware: cancelling a sleep ends it, and a sleep whose task was cancelled
/// before it registered never registers, so ``waitForSleepers(_:)`` and ``pendingSleeps`` count
/// live sleeps only.
///
/// `Clock` requires `Sendable`: the test and the sleeping effects share the clock, so its state is
/// locked.
final class GateClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleep {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct SleepWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var nextID = 0
    private var sleeps: [Int: Sleep] = [:]
    private var waiters: [Int: SleepWaiter] = [:]

    var now: Instant {
        lock.withLock { currentInstant }
    }

    var minimumResolution: Duration { .zero }

    /// The time left until each live sleep's deadline, soonest first.
    var pendingSleeps: [Duration] {
        lock.withLock { sleeps.values.map { currentInstant.duration(to: $0.deadline) }.sorted() }
    }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = makeID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (outcome, satisfiedWaiters) = lock.withLock {
                    () -> (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled { return (.failure(CancellationError()), []) }
                    guard currentInstant < deadline else { return (.success(()), []) }
                    sleeps[id] = Sleep(deadline: deadline, continuation: continuation)
                    let satisfied = waiters.filter { $0.value.count <= sleeps.count }
                    for waiterID in satisfied.keys {
                        waiters[waiterID] = nil
                    }
                    return (nil, satisfied.values.map(\.continuation))
                }
                for waiter in satisfiedWaiters {
                    waiter.resume()
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            lock.withLock { sleeps.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits until at least `count` sleeps are live (registered, neither woken nor cancelled), or
    /// until the waiting task is cancelled.
    func waitForSleepers(_ count: Int) async {
        let id = makeID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumesNow = lock.withLock {
                    guard sleeps.count < count, !Task.isCancelled else { return true }
                    waiters[id] = SleepWaiter(count: count, continuation: continuation)
                    return false
                }
                if resumesNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }

    /// Moves time forward by `duration` and wakes, before it returns, every live sleep whose
    /// deadline the new time reaches.
    func moveForward(by duration: Duration) {
        let woken = lock.withLock { () -> [Sleep] in
            currentInstant = currentInstant.advanced(by: duration)
            let due = sleeps.filter { $0.value.deadline <= currentInstant }
            for id in due.keys {
                sleeps[id] = nil
            }
            return Array(due.values)
        }
        for sleep in woken {
            sleep.continuation.resume()
        }
    }

    private func makeID() -> Int {
        lock.withLock {
            nextID += 1
            return nextID
        }
    }
}
