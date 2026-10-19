import Foundation

/// The actor shell under test (`TestModel`, `ActorModel`), for an effect to check with
/// `preconditionIsolated()` that it runs on the shell's executor. The shell's runtime is private, so
/// the check goes through the shell actor, which shares the runtime's executor.
///
/// Weak, so the interactor does not keep its shell alive, and locked: the test sets it, the effect
/// reads it on the shell's executor.
final class ActorShellReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storage: (any Actor)?

    var shell: (any Actor)? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
