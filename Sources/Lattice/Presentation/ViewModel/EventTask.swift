import Foundation

/// A handle to the effects spawned by a single `sendViewEvent` call.
///
/// Use `EventTask` to await completion of effects or cancel them.
public struct EventTask: Sendable {
    private let cancelOperation: @Sendable () -> Void
    private let finishOperation: @Sendable () async -> Void
    private let isCancelledOperation: @Sendable () -> Bool

    public let hasEffects: Bool

    init(
        hasEffects: Bool,
        cancelOperation: @escaping @Sendable () -> Void = {},
        finishOperation: @escaping @Sendable () async -> Void = {},
        isCancelledOperation: @escaping @Sendable () -> Bool = { false }
    ) {
        self.hasEffects = hasEffects
        self.cancelOperation = cancelOperation
        self.finishOperation = finishOperation
        self.isCancelledOperation = isCancelledOperation
    }

    /// Cancels all effects spawned by this event.
    public func cancel() {
        cancelOperation()
    }

    /// Awaits completion of all effects spawned by this event.
    public func finish() async {
        await finishOperation()
    }

    /// Whether this event's effects have been cancelled.
    public var isCancelled: Bool {
        isCancelledOperation()
    }
}
