import Foundation

/// A handle to the effects spawned by a single `sendViewEvent` call.
///
/// Use `EventTask` to await completion of effects or cancel them.
///
/// ## Usage
///
/// Fire-and-forget (existing pattern):
/// ```swift
/// viewModel.sendViewEvent(.increment)
/// ```
///
/// Await completion:
/// ```swift
/// await viewModel.sendViewEvent(.fetch).finish()
/// ```
///
/// Cancel:
/// ```swift
/// let task = viewModel.sendViewEvent(.longOperation)
/// task.cancel()
/// ```
///
/// ## SwiftUI Integration
///
/// Useful with `.refreshable` to await completion:
/// ```swift
/// .refreshable {
///     await viewModel.sendViewEvent(.refresh).finish()
/// }
/// ```
///
/// Or with `.task` for lifecycle-bound effects:
/// ```swift
/// .task {
///     await viewModel.sendViewEvent(.startObserving).finish()
/// }
/// ```
public struct EventTask: Sendable {
    internal let rawValue: Task<Void, Never>?

    init(rawValue: Task<Void, Never>?) {
        self.rawValue = rawValue
    }

    /// Cancels all effects spawned by this event.
    public func cancel() {
        rawValue?.cancel()
    }

    /// Awaits completion of all effects spawned by this event.
    public func finish() async {
        await rawValue?.value
    }

    /// Whether this event's effects have been cancelled.
    public var isCancelled: Bool {
        rawValue?.isCancelled ?? false
    }

    /// Whether this event spawned any effects.
    public var hasEffects: Bool {
        rawValue != nil
    }
}
