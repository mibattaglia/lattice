import Foundation

/// A type that processes **actions** and mutates a feature's **state**.
///
/// An `Interactor` is the core unit of a feature's business logic. It plays a role similar to a
/// "reducer" in other architectures: it handles each action synchronously, mutating the state it
/// is handed and enqueueing asynchronous work through the ``Effects`` handle.
///
/// ## Declaring an Interactor
///
/// Use the `@Interactor` macro for a concise declaration:
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
/// In most cases you only implement the `body` property and let the compiler infer its concrete
/// return type via Swift's result-builder machinery.
///
/// ## Custom Implementation
///
/// For advanced scenarios, implement `interact(state:action:effects:)` directly:
///
/// ```swift
/// func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
///     // Custom processing logic
/// }
/// ```
///
/// - Note: Custom `interact(state:action:effects:)` implementations take precedence over `body`.
public protocol Interactor<State, Action> {
    /// The type of state the interactor mutates.
    associatedtype State
    /// The type of actions the interactor handles.
    associatedtype Action
    /// The concrete type returned by the result-builder `body` property.
    associatedtype Body: Interactor

    /// A declarative description of this interactor constructed with ``InteractorBuilder``.
    @InteractorBuilder<State, Action>
    var body: Body { get }

    /// Mutates state synchronously and enqueues effects. Never suspends; never sends.
    ///
    /// - Parameters:
    ///   - state: The current state, passed as `inout` for mutation.
    ///   - action: The action to process.
    ///   - effects: The handle for asynchronous work (``Effects/perform(id:_:)``).
    func interact(state: inout State, action: Action, effects: Effects<State, Action>)
}

extension Interactor where Body.State == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension Interactor where Body: Interactor<State, Action> {
    /// The default implementation forwards to the `body` interactor.
    public func interact(state: inout State, action: Action, effects: Effects<State, Action>) {
        body.interact(state: &state, action: action, effects: effects)
    }
}

/// A convenience alias that exposes the `State` and `Action` associated types of an
/// ``Interactor``.
///
/// Use this alias in `body` return types:
/// ```swift
/// var body: some InteractorOf<Self> {
///     Interact { state, action, effects in ... }
/// }
/// ```
public typealias InteractorOf<I: Interactor> = Interactor<I.State, I.Action>

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

    public init<I: Interactor>(_ base: I) where I.State == State, I.Action == Action {
        self.interactFunc = { state, action, effects in
            base.interact(state: &state, action: action, effects: effects)
        }
    }

    public var body: some Interactor<State, Action> { self }

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
    public func eraseToAnyInteractor() -> AnyInteractor<State, Action> {
        AnyInteractor(self)
    }
}
