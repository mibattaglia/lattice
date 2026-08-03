import Foundation

/// A type that processes **actions** by mutating **domain state** and launching effects.
///
/// An `Interactor` is the core unit of a feature's business logic. It processes actions
/// synchronously in the host's isolation domain, mutating state in place and launching
/// imperative async effects through the ``Effects`` handle.
///
/// ## Declaring an Interactor
///
/// Use the `@Interactor` macro for a concise declaration:
///
/// ```swift
/// @Interactor<CounterState, CounterAction>
/// struct CounterInteractor {
///     var body: some InteractorOf<Self> {
///         Interact { state, action in
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
/// ## Effects
///
/// Async work is launched during the synchronous update phase and re-enters by mutating
/// state directly:
///
/// ```swift
/// Interact { state, action, effects in
///     switch action {
///     case .refresh:
///         state.isLoading = true
///         effects.perform { [api] effectState in
///             let items = try await api.fetchItems()
///             try effectState.modify { state in
///                 state.isLoading = false
///                 state.items = items
///             }
///         }
///     }
/// }
/// ```
///
/// ## Custom Implementation
///
/// For advanced scenarios, implement `interact(state:action:effects:)` directly. Custom
/// implementations take precedence over `body`.
public protocol Interactor<DomainState, Action> {
    /// The type of state this interactor mutates.
    associatedtype DomainState
    /// The type of actions this interactor processes.
    associatedtype Action
    /// The concrete type returned by the result-builder `body` property.
    associatedtype Body: Interactor

    /// A declarative description of this interactor constructed with ``InteractorBuilder``.
    ///
    /// `body` must be a pure, stable description: it is evaluated as part of the static
    /// composition tree and must return the same structure every time.
    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    /// Processes an action by mutating state and, optionally, launching effects.
    ///
    /// Runs synchronously in the host's isolation domain during the update phase.
    ///
    /// - Parameters:
    ///   - state: The current state, passed as `inout` for mutation.
    ///   - action: The action to process.
    ///   - effects: The handle for launching async effects. Only
    ///     ``Effects/perform(id:_:fileID:filePath:line:column:)`` is legal during this call;
    ///     `modify`/`send` are effect-phase APIs.
    func interact(
        state: inout DomainState,
        action: Action,
        effects: Effects<DomainState, Action>
    )
}

extension Interactor where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension Interactor where Body: Interactor<DomainState, Action> {
    /// The default implementation forwards to the `body` interactor, threading the effects
    /// handle unchanged (composition nodes, not `body` itself, append path components).
    public func interact(
        state: inout DomainState,
        action: Action,
        effects: Effects<DomainState, Action>
    ) {
        body.interact(state: &state, action: action, effects: effects)
    }
}

/// A convenience alias that exposes the `DomainState` and `Action` associated types of an
/// ``Interactor``.
public typealias InteractorOf<I: Interactor> = Interactor<I.DomainState, I.Action>

/// A type-erased wrapper around any ``Interactor``.
///
/// Use `AnyInteractor` when you need to store interactors with different concrete types
/// but the same `State` and `Action` types:
///
/// ```swift
/// let interactor: AnyInteractor<MyState, MyAction> = CounterInteractor()
///     .eraseToAnyInteractor()
/// ```
public struct AnyInteractor<State, Action>: Interactor {
    private let interactFunc: (inout State, Action, Effects<State, Action>) -> Void

    public init<I: Interactor>(_ base: I) where I.DomainState == State, I.Action == Action {
        self.interactFunc = { state, action, effects in
            base.interact(state: &state, action: action, effects: effects)
        }
    }

    public var body: some Interactor<State, Action> { self }

    /// Structurally transparent: forwards the handle unmodified, so erasure never perturbs
    /// `GraphPath`s.
    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
        interactFunc(&state, action, effects)
    }
}

extension Interactor {
    /// Erases this interactor to ``AnyInteractor``.
    ///
    /// Use this when you need to store interactors of different types uniformly:
    /// ```swift
    /// let interactors: [AnyInteractor<State, Action>] = [
    ///     CounterInteractor().eraseToAnyInteractor(),
    ///     LoggingInteractor().eraseToAnyInteractor()
    /// ]
    /// ```
    public func eraseToAnyInteractor() -> AnyInteractor<DomainState, Action> {
        AnyInteractor(self)
    }
}
