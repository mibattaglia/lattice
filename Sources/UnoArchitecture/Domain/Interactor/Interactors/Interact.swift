import Foundation

/// The core primitive for handling actions and emitting state within an ``Interactor``.
///
/// `Interact` is the fundamental building block of the interactor system. It processes
/// actions through a handler closure that returns an ``Emission`` describing how to
/// emit the next state.
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
///             return .state
///         }
///     }
/// }
/// ```
///
/// ## Emission Types
///
/// The handler returns an ``Emission`` that controls how state is emitted:
///
/// - **`.state`**: Emit the mutated state immediately
/// - **`.perform { state, send in ... }`**: Execute async work, then emit via `send`
/// - **`.observe { state, send in ... }`**: Observe a stream, emitting for each element
///
/// ## Async Work Example
///
/// ```swift
/// Interact { state, action in
///     switch action {
///     case .fetchData:
///         state.isLoading = true
///         return .perform { [api] state, send in
///             let data = try await api.fetch()
///             var currentState = await state.current
///             currentState.isLoading = false
///             currentState.data = data
///             await send(currentState)
///         }
///     }
/// }
/// ```
///
/// ## State Management
///
/// - The handler receives an `inout State` that can be mutated directly
/// - State mutations are applied before the emission is processed
/// - For async work, use ``DynamicState`` to read the latest state
/// - Use ``Send`` to emit state updates from async contexts
public struct Interact<State: Sendable, Action: Sendable>: Interactor, @unchecked Sendable {
    /// The type of the handler closure that processes actions.
    public typealias Handler = (inout State, Action) -> Emission<State>

    private let handler: Handler

    /// Creates an `Interact` primitive with the given handler.
    ///
    /// - Parameter handler: A closure that processes actions and returns an ``Emission``.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action) -> Emission<State> {
        handler(&state, action)
    }
}
