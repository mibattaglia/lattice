import Foundation

/// The core primitive for handling actions and emitting state within an ``Interactor``.
///
/// `Interact` is the fundamental building block of the interactor system. It processes
/// actions through a handler closure that returns an ``Emission`` describing what
/// actions to emit.
///
/// ## Basic Usage
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor: Sendable {
///     var body: some InteractorOf<Self> {
///         Interact { state, action in
///             switch action {
///             case .increment:
///                 state.count += 1
///             case .decrement:
///                 state.count -= 1
///             }
///             return .none
///         }
///     }
/// }
/// ```
///
/// ## Emission Types
///
/// The handler returns an ``Emission`` that controls what happens next:
///
/// - **`.none`**: No action to emit, state was mutated synchronously
/// - **`.action(action)`**: Emit a single action immediately
/// - **`.perform { ... }`**: Execute async work, return an action when done
/// - **`.observe { ... }`**: Observe a stream, emitting actions for each element
///
/// ## Async Work Example
///
/// ```swift
/// Interact { state, action in
///     switch action {
///     case .fetchData:
///         state.isLoading = true
///         return .perform { [api] in
///             let data = try await api.fetch()
///             return .dataLoaded(data)
///         }
///     case .dataLoaded(let data):
///         state.isLoading = false
///         state.data = data
///         return .none
///     }
/// }
/// ```
///
/// ## State Management
///
/// - The handler receives an `inout State` that can be mutated directly
/// - State mutations are applied before the emission is processed
/// - Effects return actions that are fed back through the interactor
public struct Interact<State: Sendable, Action: Sendable>: Interactor, @unchecked Sendable {
    /// The type of the handler closure that processes actions.
    public typealias Handler = (inout State, Action) -> Emission<Action>

    private let handler: Handler

    /// Creates an `Interact` primitive with the given handler.
    ///
    /// - Parameter handler: A closure that processes actions and returns an ``Emission``.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action) -> Emission<Action> {
        handler(&state, action)
    }
}
