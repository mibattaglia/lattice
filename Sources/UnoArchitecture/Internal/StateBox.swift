import Foundation

/// A mutable state container used internally by ``Interact``.
///
/// `StateBox` holds the current state value and provides synchronous access
/// within the `@MainActor` context. It is marked as `@unchecked Sendable`
/// because all access occurs on the main actor.
///
/// - Note: This is an internal type not intended for direct use.
@MainActor
final class StateBox<State>: @unchecked Sendable {
    /// The current state value.
    var value: State

    /// Creates a new state box with the given initial value.
    ///
    /// - Parameter initial: The initial state value.
    init(_ initial: State) {
        self.value = initial
    }
}
