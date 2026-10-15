import Clocks
import Foundation

/// An ordered log that effects, cancellation handlers and tests append to.
///
/// Effects run on their model's isolation, but a cancellation handler runs on whichever thread
/// cancels, so appends are locked.
final class EffectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var entries: [String] { lock.withLock { storage } }

    func append(_ entry: String) {
        lock.withLock { storage.append(entry) }
    }

    /// Sleeps on `clock` until the effect is cancelled, appending `cancelledEntry` the moment it is.
    ///
    /// The tests never advance the clock: `TestClock.sleep` is `@concurrent`, so it registers its
    /// sleeper on the global executor after the effect hops there, and an `advance` right after the
    /// send would race that registration. Cancellation ends the sleep whether or not it registered.
    ///
    /// `nonisolated(nonsending)`, so the cancellation handler is installed on the effect's isolation
    /// before its first suspension: a cancel issued by a later `send` appends synchronously, before
    /// that `send` returns.
    nonisolated(nonsending) func sleepUntilCancelled(
        on clock: TestClock<Duration>,
        appendingOnCancel cancelledEntry: String
    ) async throws {
        try await withTaskCancellationHandler {
            try await clock.sleep(for: .seconds(1_000))
        } onCancel: {
            self.append(cancelledEntry)
        }
    }
}

/// A suspension point the test resumes: deterministic, unlike a `TestClock` advanced right after
/// the effect started.
///
/// `wait()` is `nonisolated(nonsending)`, so the continuation is stored on the effect's isolation
/// before the effect suspends; `open()` resumes every waiting effect.
final class EffectGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    /// Waits until `open()`, ignoring cancellation.
    nonisolated(nonsending) func wait() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    /// Waits until `open()`, then throws `CancellationError` if the effect was cancelled meanwhile:
    /// a cancellation-aware suspension point whose end the test controls.
    nonisolated(nonsending) func pass() async throws {
        await wait()
        try Task.checkCancellation()
    }

    func open() {
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}
