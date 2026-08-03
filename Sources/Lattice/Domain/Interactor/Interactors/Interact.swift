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
    /// The type of the legacy handler closure that processes actions and returns an ``Emission``.
    public typealias Handler = (inout State, Action) -> Emission<Action>

    /// The type of the handler closure that mutates state and may launch effects.
    public typealias EffectsHandler = (inout State, Action, Effects<State, Action>) -> Void

    private enum Storage {
        case emission(Handler)
        case effects(EffectsHandler)
    }

    private let storage: Storage

    /// Creates an `Interact` primitive with the given handler.
    ///
    /// - Parameter handler: A closure that processes actions and returns an ``Emission``.
    public init(handler: @escaping Handler) {
        self.storage = .emission(handler)
    }

    /// Creates an `Interact` primitive with the given effects handler.
    ///
    /// The handler receives the update-phase ``Effects`` handle unmodified (`Interact` is a
    /// leaf: it appends no structural path component). A second `effects.perform` triggered
    /// from the *same* call site replaces the previous in-flight task automatically
    /// (per-call-site auto-replacement) — see ``Effects/perform(id:_:fileID:filePath:line:column:)``.
    ///
    /// Interactors that never launch effects ignore the third parameter (`{ state, action, _ in … }`);
    /// the two-argument `Void` convenience arrives when plan 06 deletes the legacy ``Emission``
    /// handler (a multi-statement closure's return type cannot disambiguate the two while both
    /// two-argument shapes exist).
    ///
    /// - Parameter handler: A closure that mutates state and may launch effects.
    public init(handler: @escaping EffectsHandler) {
        self.storage = .effects(handler)
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action) -> Emission<Action> {
        switch storage {
        case .emission(let handler):
            return handler(&state, action)
        case .effects(let handler):
            // Transitional: an effects-style handler hosted by the legacy Emission runtime
            // runs with a detached handle — mutations apply; `perform` reports an issue.
            handler(&state, action, _detachedEffectsHandle(path: GraphPath()))
            return .none
        }
    }

    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
        switch storage {
        case .emission(let handler):
            // Transitional mutation-only bridge: the returned emission is discarded on the
            // imperative-effect pathway.
            _ = handler(&state, action)
        case .effects(let handler):
            handler(&state, action, effects)
        }
    }
}
