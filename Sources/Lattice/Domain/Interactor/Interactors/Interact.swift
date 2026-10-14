import Foundation

/// The core primitive for handling actions within an ``Interactor``.
///
/// `Interact` processes actions through a handler closure that mutates the state it is handed and
/// enqueues asynchronous work through the ``Effects`` handle.
///
/// ## Basic Usage
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor {
///     var body: some InteractorOf<Self> {
///         Interact { state, action, effects in
///             switch action {
///             case .increment:
///                 state.count += 1
///             case .decrement:
///                 state.count -= 1
///             }
///         }
///     }
/// }
/// ```
///
/// ## Async Work Example
///
/// An effect delivers its result by modifying state; no response action is needed:
///
/// ```swift
/// Interact { state, action, effects in
///     switch action {
///     case .fetchData:
///         state.isLoading = true
///         effects.perform {
///             defer { try? effects.modify { $0.isLoading = false } }
///             let data = try await api.fetch()
///             try effects.modify { $0.data = data }
///         }
///     }
/// }
/// ```
///
/// ## State Management
///
/// - The handler receives an `inout State` that can be mutated directly.
/// - Effects performed during the handler start after it returns, in `perform` order.
/// - Effects change state through ``Effects/modify(_:)`` and send actions through
///   ``Effects/send(_:)`` only to start new effects or run interactor logic.
public struct Interact<State, Action>: Interactor {
    /// The type of the handler closure that processes actions.
    public typealias Handler = (inout State, Action, Effects<State, Action>) -> Void

    private let handler: Handler

    /// Creates an `Interact` primitive with the given handler.
    ///
    /// - Parameter handler: A closure that mutates state and enqueues effects for each action.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
        handler(&state, action, effects)
    }
}
