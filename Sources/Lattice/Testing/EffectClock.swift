import Foundation
import IssueReporting

/// A clock for tests: time moves only when the test shell's `advance` moves it, and an effect's
/// sleep is registered before the `send` that started the effect returns.
///
/// ```swift
/// let clock = EffectClock()
/// let model = await TestModel(
///     initialState: SearchState(),
///     feature: Feature(interactor: SearchInteractor(clock: clock, debounceDuration: .milliseconds(300)))
/// )
/// await model.send(.queryChanged("a")) { $0.query = "a" }
/// await model.send(.queryChanged("b")) { $0.query = "b" }  // auto-cancels "a" while it sleeps
/// await model.advance(clock, by: .milliseconds(300))  // "b" wakes, searches and writes its results
/// await model.expect { $0.results = ["b"] }
/// await model.finish()
/// ```
///
/// - Effects sleep with `try await clock.sleep(for:)`. That overload is `nonisolated(nonsending)`:
///   it registers the sleep on the effect's isolation, before the effect first suspends.
/// - ``TestModel/advance(_:by:)`` and ``TestViewModel/advance(_:by:)`` wake the sleeps that come due,
///   one at a time in deadline order, and return only after each woken effect has run to its next
///   suspension.
/// - Sleeps are cancellation-aware: cancelling a sleeping effect removes its sleep and ends it inside
///   the `cancel()` call. A sleep whose task is already cancelled throws without registering.
/// - `sleep(until:tolerance:)` is the `Clock` requirement. Called on an `EffectClock`, it registers
///   on the caller's isolation too. The standard library's `sleep(for:tolerance:)`,
///   `Task.sleep(for:clock:)` and `sleep(until:tolerance:)` on a generic clock reach it only after
///   hopping off the effect's isolation, and so does any sleep in a `@concurrent` function: such a
///   sleep is reported, then registers late, and an `advance` right after `send` can miss it.
///
/// Use one clock per test model: `advance` can promise that a woken effect has reached its next
/// suspension only for effects on its own shell's executor. `Clock` requires `Sendable`: the effects
/// and the test share the clock, so its state is locked.
public final class EffectClock: Clock, @unchecked Sendable {
    /// A point in the clock's time: how far it is from the clock's start.
    public struct Instant: InstantProtocol {
        public let offset: Duration

        public init(offset: Duration = .zero) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    /// A registered sleep. `continuation` is `nil` until its task has suspended.
    private struct Sleeper {
        let deadline: Instant
        var continuation: UnsafeContinuation<Void, any Error>?
    }

    private let lock = NSLock()
    private var currentInstant: Instant
    private var nextSleeperID = 0
    private var sleepers: [Int: Sleeper] = [:]
    /// How the sleeps ended that were woken or cancelled before their task suspended.
    private var earlyOutcomes: [Int: Result<Void, any Error>] = [:]
    /// The sleeps ``wakeEarliestSleeper(dueBy:)`` woke whose effect has not run on its isolation since.
    private var wokenEffectsYetToRun: Set<Int> = []
    /// The `advance` calls ``letWokenEffectRun(_:)`` holds until the woken effect has run, by sleep.
    private var heldAdvances: [Int: CheckedContinuation<Void, Never>] = [:]

    /// Creates a clock whose time starts at `now`.
    public init(now: Instant = Instant()) {
        currentInstant = now
    }

    public var now: Instant {
        lock.withLock { currentInstant }
    }

    public var minimumResolution: Duration { .zero }

    /// The number of live sleeps: registered, neither woken nor cancelled.
    ///
    /// Internal, as is ``pendingDeadlines``: the library's tests read the live sleeps to check
    /// registration and cancellation, and a feature's tests observe time only through `advance`.
    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    /// The deadline of each live sleep, soonest first.
    var pendingDeadlines: [Instant] {
        lock.withLock { sleepers.values.map(\.deadline).sorted() }
    }

    /// The `Clock` requirement, for the spellings that skip `clock.sleep(for:)`.
    ///
    /// Called on an `EffectClock`, it runs on the caller's isolation and registers the sleep there.
    /// Reached through `Clock` (`sleep(for:tolerance:)`, `Task.sleep(for:clock:)`, a generic clock),
    /// it runs only after the standard library's hop off the caller's isolation, with none: the sleep
    /// registers late, and an `advance` right after `send` can miss it. It reports such a call, then
    /// sleeps.
    public nonisolated(nonsending) func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        // Bound first: `#isolation == nil` written inline crashes Swift 6.4's IRGen in a
        // `nonisolated(nonsending)` function.
        let callerIsolation = #isolation
        if callerIsolation == nil {
            reportIssue(Self.lateSleepMessage)
        }
        try await registerAndSleep { _ in deadline }
    }

    /// Wakes the live sleep with the earliest deadline at or before `target`, after moving time to
    /// that deadline, and returns it for ``letWokenEffectRun(_:)``. Returns `nil`, and changes
    /// nothing, when no sleep is due by `target`.
    fileprivate func wakeEarliestSleeper(dueBy target: Instant) -> Int? {
        var woken: UnsafeContinuation<Void, any Error>?
        let wokenID = lock.withLock { () -> Int? in
            guard
                let earliest = sleepers.min(by: { ($0.value.deadline, $0.key) < ($1.value.deadline, $1.key) }),
                earliest.value.deadline <= target
            else { return nil }
            sleepers[earliest.key] = nil
            currentInstant = max(currentInstant, earliest.value.deadline)
            wokenEffectsYetToRun.insert(earliest.key)
            if let continuation = earliest.value.continuation {
                woken = continuation
            } else {
                earlyOutcomes[earliest.key] = .success(())
            }
            return earliest.key
        }
        woken?.resume()
        return wokenID
    }

    /// Returns once the effect that ``wakeEarliestSleeper(dueBy:)`` woke from `sleep` has run on its
    /// isolation to its next suspension. This barrier is why `advance` returns only after each woken
    /// effect has run to its next suspension, and wakes the next sleep only then.
    ///
    /// A `Task.yield()` is not enough: a resumed continuation does not put the effect back on its
    /// isolation at once. The effect resumes on the global executor and then hops back, so a yield
    /// races that hop. The woken sleep signals instead from inside the effect's own job, once it is
    /// back on its isolation, and a caller on that same serial executor resumes only after the job
    /// has reached its next suspension.
    fileprivate nonisolated(nonsending) func letWokenEffectRun(_ sleep: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hasRun = lock.withLock { () -> Bool in
                guard wokenEffectsYetToRun.contains(sleep) else { return true }
                heldAdvances[sleep] = continuation
                return false
            }
            if hasRun {
                continuation.resume()
            }
        }
    }

    /// Moves time to `instant` if that is later than now, waking nothing.
    fileprivate func move(to instant: Instant) {
        lock.withLock { currentInstant = max(currentInstant, instant) }
    }

    static let lateSleepMessage = """
        EffectClock registered this sleep late: it reached the clock after hopping off the effect's \
        isolation, so an 'advance' right after 'send' can miss it. Sleep with 'clock.sleep(for:)' on \
        the effect's isolation: 'sleep(for:tolerance:)', 'Task.sleep(for:clock:)', \
        'sleep(until:tolerance:)' on a generic clock and any sleep in a '@concurrent' function reach \
        the clock only after that hop.
        """

    /// Registers a sleep until `deadline(now)`, then suspends until it is woken or its task is
    /// cancelled. Everything before the suspension is synchronous, so a caller on an effect's
    /// isolation is registered before the effect first suspends.
    private nonisolated(nonsending) func registerAndSleep(
        until deadline: (_ now: Instant) -> Instant
    ) async throws {
        try Task.checkCancellation()
        let registeredID = lock.withLock { () -> Int? in
            let deadline = deadline(currentInstant)
            guard currentInstant < deadline else { return nil }  // already due: no suspension
            let id = nextSleeperID
            nextSleeperID += 1
            sleepers[id] = Sleeper(deadline: deadline)
            return id
        }
        guard let id = registeredID else { return }
        // Runs on the caller's isolation once the sleep is over (the hop back is part of the
        // continuation's resumption), so the `advance` it releases resumes behind this job.
        defer { didRunAfterWaking(id) }
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                let earlyOutcome = lock.withLock { () -> Result<Void, any Error>? in
                    guard sleepers[id] != nil else { return earlyOutcomes.removeValue(forKey: id) }
                    sleepers[id]?.continuation = continuation
                    return nil
                }
                if let earlyOutcome {
                    continuation.resume(with: earlyOutcome)
                }
            }
        } onCancel: {
            cancelSleeper(id)
        }
    }

    /// Removes the sleep and ends it with `CancellationError`, inside the `cancel()` call that
    /// cancelled its task. Does nothing when it was already woken.
    private func cancelSleeper(_ id: Int) {
        let continuation = lock.withLock { () -> UnsafeContinuation<Void, any Error>? in
            guard let sleeper = sleepers.removeValue(forKey: id) else { return nil }
            if sleeper.continuation == nil {
                earlyOutcomes[id] = .failure(CancellationError())
            }
            return sleeper.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    /// Marks the effect of the woken sleep `id` as run, from inside its job on its isolation, and
    /// releases the `advance` that ``letWokenEffectRun(_:)`` holds for it, if any. Does nothing for a
    /// sleep that was not woken.
    private func didRunAfterWaking(_ id: Int) {
        let heldAdvance = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard wokenEffectsYetToRun.remove(id) != nil else { return nil }
            return heldAdvances.removeValue(forKey: id)
        }
        heldAdvance?.resume()
    }
}

extension EffectClock: SleepRegistrar {
    /// `clock.sleep(for:)` on an `EffectClock`: registers the sleep on the caller's isolation. A
    /// caller without one, such as a `@concurrent` function, already hopped off the effect's
    /// isolation, so the sleep is reported, then registers late.
    nonisolated(nonsending) func registerSleep(for duration: Duration) async throws {
        let callerIsolation = #isolation  // bound first, as in `sleep(until:tolerance:)`
        if callerIsolation == nil {
            reportIssue(Self.lateSleepMessage)
        }
        try await registerAndSleep { $0.advanced(by: duration) }
    }
}

@available(iOS 26, macOS 26, watchOS 26, *)
extension TestModel {
    /// Moves `clock` forward by `duration`: wakes every sleep that comes due, in deadline order, and
    /// lets each woken effect run to its next suspension before it wakes the next one.
    ///
    /// Time moves to each sleep's deadline as it wakes it, so a loop that sleeps again is due one
    /// interval later and is woken again while that is within `duration`: one call moves a ticker
    /// through every tick in that time. When it returns, each woken effect has committed what it
    /// commits before its next suspension, pending for `expect`, and has slept again, finished or
    /// parked on something other than the clock, which does not hold the call up.
    ///
    /// Effects must sleep with `clock.sleep(for:)`, which registers the sleep before `send` returns.
    /// A sleep that reaches the clock after a hop off the model's isolation is reported, and this
    /// call can miss it. Runs on the model's executor, where its effects run.
    public func advance(_ clock: EffectClock, by duration: Duration) async {
        let target = clock.now.advanced(by: duration)
        while let woken = clock.wakeEarliestSleeper(dueBy: target) {
            await clock.letWokenEffectRun(woken)
        }
        clock.move(to: target)
    }
}

@MainActor
extension TestViewModel {
    /// Moves `clock` forward by `duration`: wakes every sleep that comes due, in deadline order, and
    /// lets each woken effect run to its next suspension before it wakes the next one; see
    /// ``TestModel/advance(_:by:)``. Runs on the main actor, where the feature's effects run.
    public func advance(_ clock: EffectClock, by duration: Duration) async {
        let target = clock.now.advanced(by: duration)
        while let woken = clock.wakeEarliestSleeper(dueBy: target) {
            await clock.letWokenEffectRun(woken)
        }
        clock.move(to: target)
    }
}
