import Foundation

/// An ordered log for what state cannot hold, which is the only thing it is for: what an effect sees
/// after it may no longer write state, once its model was invalidated or deallocated or its
/// case-scoped child state went away. Everything else a test records in state, where the test shell
/// asserts it.
///
/// The one other use is the checkpoints of the three isolation suites (`ViewModelIsolationTests`,
/// `TestModelIsolationTests`, `ActorModelIsolationTests`), one of them from a cancellation handler:
/// they keep swift-clocks' `TestClock` for its real `@concurrent` hop.
///
/// Locked: effects and cancellation handlers append on the model's isolation, and a test reads
/// from its own while a cancelled effect may still be appending.
final class EffectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var entries: [String] { lock.withLock { storage } }

    func append(_ entry: String) {
        lock.withLock { storage.append(entry) }
    }
}
