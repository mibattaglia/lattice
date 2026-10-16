import Foundation

/// The task an effect got back from its own `effects.send`. Locked: the effect sets it on its model's
/// executor, and the test reads it.
final class LockedNestedTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
