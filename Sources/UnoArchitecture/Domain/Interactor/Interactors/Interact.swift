import AsyncAlgorithms
import Foundation

/// The core primitive for handling actions and emitting state within an ``Interactor``.
///
/// `Interact` is the fundamental building block of the interactor system. It maintains
/// state and processes actions through a handler closure that returns an ``Emission``
/// describing how to emit the next state.
///
/// ## Basic Usage
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor: Sendable {
///     var body: some InteractorOf<Self> {
///         Interact(initialValue: CounterState()) { state, action in
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
/// Interact(initialValue: State()) { state, action in
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
///
/// - Note: The handler runs on `@MainActor` to ensure thread-safe state access.
public struct Interact<State: Sendable, Action: Sendable>: Interactor, @unchecked Sendable {
    /// The type of the handler closure that processes actions.
    public typealias Handler = @MainActor (inout State, Action) -> Emission<State>

    private let initialValue: State
    private let handler: Handler

    /// Creates an `Interact` primitive with the given initial state and handler.
    ///
    /// - Parameters:
    ///   - initialValue: The initial state value, emitted when the interactor starts.
    ///   - handler: A closure that processes actions and returns an ``Emission``.
    public init(initialValue: State, handler: @escaping Handler) {
        self.initialValue = initialValue
        self.handler = handler
    }

    public var body: some Interactor<State, Action> { self }

    /// Transforms the upstream action stream into a stream of domain state.
    ///
    /// This method implements the core feedback loop:
    /// 1. Emits the initial state
    /// 2. For each action, calls the handler to get the new state and emission
    /// 3. Processes the emission (`.state`, `.perform`, or `.observe`)
    /// 4. Cancels effect tasks when the upstream finishes
    ///
    /// - Parameter upstream: The stream of actions to process.
    /// - Returns: A stream of state values.
    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        let initialValue = self.initialValue
        let handler = self.handler

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                let stateBox = StateBox(initialValue)
                var effectTasks: [Task<Void, Never>] = []

                let send = Send<State> { newState in
                    stateBox.value = newState
                    continuation.yield(newState)
                }

                continuation.yield(stateBox.value)

                for await action in upstream {
                    var state = stateBox.value
                    let emission = handler(&state, action)
                    stateBox.value = state

                    switch emission.kind {
                    case .state:
                        continuation.yield(state)

                    case .perform(let work):
                        let dynamicState = DynamicState {
                            await MainActor.run { stateBox.value }
                        }
                        let effectTask = Task {
                            await work(dynamicState, send)
                        }
                        effectTasks.append(effectTask)

                    case .observe(let streamWork):
                        let dynamicState = DynamicState {
                            await MainActor.run { stateBox.value }
                        }
                        let effectTask = Task {
                            await streamWork(dynamicState, send)
                        }
                        effectTasks.append(effectTask)
                    }
                }

                effectTasks.forEach { $0.cancel() }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
