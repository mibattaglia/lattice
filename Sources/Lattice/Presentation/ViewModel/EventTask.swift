import Foundation

/// A handle to the root send scope started by a single `sendViewEvent` call.
///
/// Use `EventTask` to await transitive effect completion or cancel the in-flight work owned by that send.
///
/// `EventTask` tracks a root send scope, not only the first generation of tasks created by an
/// action. If an effect emits more actions and those actions start more work, that downstream work
/// remains part of the same scope.
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

    /// Cancels all currently in-flight effects owned by this event's root send scope.
    public func cancel() {
        rawValue?.cancel()
    }

    /// Awaits quiescence of this event's root send scope, including recursively emitted child effects.
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
