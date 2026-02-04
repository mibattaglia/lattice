import Foundation

/// A callback for emitting state updates from effect closures.
///
/// `Send` is used within `.perform` and `.observe` emissions to emit state
/// updates back to the interactor from async contexts.
///
/// ## Usage
///
/// ```swift
/// return .perform { state, send in
///     let data = try await api.fetchData()
///     var currentState = await state.current
///     currentState.data = data
///     await send(currentState)
/// }
/// ```
///
/// ## Thread Safety
///
/// `Send` is `@MainActor` isolated, ensuring all state mutations occur on the
/// main thread. When called from a non-isolated async context, Swift automatically
/// handles the actor hop via `await`.
///
/// ## Cancellation
///
/// `Send` automatically checks for task cancellation before emitting. If the
/// task has been cancelled, the state update is silently dropped.
///
/// - Note: Inspired by The Composable Architecture's `Send` type.
@MainActor
public struct Send<State: Sendable>: Sendable {
    private let yield: @MainActor (State) -> Void

    init(_ yield: @escaping @MainActor (State) -> Void) {
        self.yield = yield
    }

    /// Emits a new state if the current task is not cancelled.
    ///
    /// Call this as a function to emit state:
    /// ```swift
    /// await send(newState)
    /// ```
    ///
    /// - Parameter state: The new state to emit.
    public func callAsFunction(_ state: State) {
        guard !Task.isCancelled else { return }
        yield(state)
    }
}
