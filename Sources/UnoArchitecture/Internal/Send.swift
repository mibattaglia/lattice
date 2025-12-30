import Foundation

/// A callback for emitting state updates from effects.
///
/// `Send` is `@MainActor` isolated, ensuring all state mutations occur on the
/// main thread. When called from a non-isolated async context (like an effect
/// closure), Swift automatically handles the actor hop.
///
/// Inspired by The Composable Architecture's `send` function.
@MainActor
public struct Send<State: Sendable>: Sendable {
    private let yield: @MainActor (State) -> Void

    init(_ yield: @escaping @MainActor (State) -> Void) {
        self.yield = yield
    }

    /// Emits a new state if the current task is not cancelled.
    public func callAsFunction(_ state: State) {
        guard !Task.isCancelled else { return }
        yield(state)
    }
}
