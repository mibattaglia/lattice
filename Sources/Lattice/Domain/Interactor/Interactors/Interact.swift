import Foundation

/// The core primitive for handling actions within an ``Interactor``.
///
/// `Interact` is the leaf of the composition tree: it hands the ``Effects`` handle it
/// receives directly to the consumer closure, appending no structural path component.
///
/// ## Basic Usage
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor {
///     var body: some InteractorOf<Self> {
///         Interact { state, action in
///             switch action {
///             case .increment: state.count += 1
///             case .decrement: state.count -= 1
///             }
///         }
///     }
/// }
/// ```
///
/// ## Async Work
///
/// ```swift
/// Interact { state, action, effects in
///     switch action {
///     case .fetchData:
///         state.isLoading = true
///         effects.perform { [api] effectState in
///             let data = try await api.fetch()
///             try effectState.modify { state in
///                 state.isLoading = false
///                 state.data = data
///             }
///         }
///     }
/// }
/// ```
///
/// A second `effects.perform` triggered from the *same* call site replaces the previous
/// in-flight task automatically (per-call-site auto-replacement), which is how debouncing and
/// search-as-you-type are expressed — see ``Effects/perform(id:_:fileID:filePath:line:column:)``.
public struct Interact<State, Action>: Interactor {
    /// The type of the handler closure that processes actions.
    public typealias Handler = (inout State, Action, Effects<State, Action>) -> Void

    private let handler: Handler

    /// Creates an `Interact` primitive with the given handler.
    ///
    /// - Parameter handler: A closure that mutates state and may launch effects.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Creates an `Interact` primitive for pure state mutation.
    ///
    /// Convenience for interactors that never launch effects; the effects handle is
    /// dropped so call sites don't need a `, _ in` placeholder.
    public init(handler: @escaping (inout State, Action) -> Void) {
        self.handler = { state, action, _ in handler(&state, action) }
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
        handler(&state, action, effects)
    }
}
