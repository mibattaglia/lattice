import Foundation

/// A handle to the effects launched by a single `sendViewEvent` call.
///
/// Use `EventTask` to await effect completion or cancel the in-flight work launched by
/// that send.
///
/// `EventTask` covers the effects the send launched directly. If an effect re-enters the
/// interactor with `effectState.send`, the work that update launches is an independent unit with
/// its own task (returned by `effectState.send`); it does not extend this handle. Direct state
/// mutation via `effectState.modify` commits synchronously and spawns no work.
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

    /// Cancels the in-flight effects launched by this send.
    ///
    /// Cancellation propagates to each directly launched effect task; effects observe it
    /// cooperatively (`modify` throws, `Task.isCancelled`), and ``finish()`` returns once
    /// they have wound down.
    public func cancel() {
        rawValue?.cancel()
    }

    /// Awaits completion of every effect this send launched directly.
    ///
    /// Effects cancelled along the way (auto-replacement by a later send at the same call
    /// site, case-exit transition detection, host teardown) complete as they wind down, so
    /// `finish()` always returns.
    public func finish() async {
        await rawValue?.value
    }

    /// Whether this event's effects have been cancelled.
    public var isCancelled: Bool {
        rawValue?.isCancelled ?? false
    }

    /// Whether this event spawned any effects.
    ///
    /// `false` iff the update launched no effects (a no-effect send yields an immediate
    /// ``finish()``). An effect that completes synchronously still counts as launched.
    public var hasEffects: Bool {
        rawValue != nil
    }
}
