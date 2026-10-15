import Foundation

/// A clock whose time moves only when the test moves it, and only after the test has seen the
/// sleeps it means to end.
///
/// `TestClock.advance` right after a send races the sleep it should end: `Clock.sleep` is
/// `@concurrent`, so an effect registers its sleep only after it has hopped off the model's
/// executor, and `advance` can scan the sleepers before that. Here the test first awaits the
/// registration with ``waitForSleepers(_:)``, then moves time with ``moveForward(by:)``, which
/// wakes every sleep it reaches before it returns. Nothing is left to timing.
///
/// Sleeps are cancellation-aware. Cancelling a registered sleep ends it inside the `cancel()` call,
/// and a sleep whose task was cancelled before it registered never registers, so
/// ``waitForSleepers(_:)`` and ``pendingSleeps`` count live sleeps only. Given a log, the clock
/// appends each sleep's lifecycle, numbered in the order the sleeps start: "sleep 1 for 0.3
/// seconds" when it registers, then "sleep 1 cancelled" or "sleep 1 woke".
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
        let number: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct SleepWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private let log: EffectLog?
    private var currentInstant = Instant(offset: .zero)
    private var startedSleepCount = 0
    private var sleeps: [Int: Sleep] = [:]
    private var nextWaiterID = 0
    private var waiters: [Int: SleepWaiter] = [:]

    init(log: EffectLog? = nil) {
        self.log = log
    }

    var now: Instant {
        lock.withLock { currentInstant }
    }

    var minimumResolution: Duration { .zero }

    /// The time left until each live sleep's deadline, soonest first.
    var pendingSleeps: [Duration] {
        lock.withLock { sleeps.values.map { currentInstant.duration(to: $0.deadline) }.sorted() }
    }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let number = lock.withLock {
            startedSleepCount += 1
            return startedSleepCount
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (outcome, satisfiedWaiters) = lock.withLock {
                    () -> (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled {
                        log?.append("sleep \(number) cancelled")
                        return (.failure(CancellationError()), [])
                    }
                    guard currentInstant < deadline else { return (.success(()), []) }
                    sleeps[number] = Sleep(number: number, deadline: deadline, continuation: continuation)
                    log?.append("sleep \(number) for \(currentInstant.duration(to: deadline))")
                    return (nil, takeSatisfiedWaiters())
                }
                for waiter in satisfiedWaiters {
                    waiter.resume()
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> Sleep? in
                guard let sleep = sleeps.removeValue(forKey: number) else { return nil }
                log?.append("sleep \(number) cancelled")
                return sleep
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits until at least `count` sleeps are live (registered, neither woken nor cancelled), or
    /// until the waiting task is cancelled.
    func waitForSleepers(_ count: Int) async {
        let id = lock.withLock {
            nextWaiterID += 1
            return nextWaiterID
        }
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
    /// deadline the new time reaches, soonest first.
    func moveForward(by duration: Duration) {
        let woken = lock.withLock { () -> [Sleep] in
            currentInstant = currentInstant.advanced(by: duration)
            let due = sleeps.values
                .filter { $0.deadline <= currentInstant }
                .sorted { ($0.deadline, $0.number) < ($1.deadline, $1.number) }
            for sleep in due {
                sleeps[sleep.number] = nil
                log?.append("sleep \(sleep.number) woke")
            }
            return due
        }
        for sleep in woken {
            sleep.continuation.resume()
        }
    }

    /// The waiters whose count the live sleeps now reach, removed. Called under `lock`.
    private func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
        let satisfied = waiters.filter { $0.value.count <= sleeps.count }
        for id in satisfied.keys {
            waiters[id] = nil
        }
        return satisfied.values.map(\.continuation)
    }
}
