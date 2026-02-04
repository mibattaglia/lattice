import Foundation

/// A type that processes **actions** and produces **domain state**.
///
/// An `Interactor` is the core unit of a feature's business logic. It plays a role similar to a
/// "reducer" in other architectures, processing actions synchronously and returning an `Emission`
/// that describes how to emit state (immediately or via an async effect).
///
/// ## Declaring an Interactor
///
/// Use the `@Interactor` macro for a concise declaration:
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
/// In most cases you only implement the `body` property and let the compiler infer its concrete
/// return type via Swift's result-builder machinery.
///
/// ## Custom Implementation
///
/// For advanced scenarios, implement `interact(state:action:)` directly:
///
/// ```swift
/// func interact(state: inout DomainState, action: Action) -> Emission<Action> {
///     // Custom processing logic
///     return .none
/// }
/// ```
///
/// - Note: Custom `interact(state:action:)` implementations take precedence over `body`.
public protocol Interactor<DomainState, Action> {
    /// The type of state produced downstream.
    associatedtype DomainState: Sendable
    /// The type of actions received upstream.
    associatedtype Action: Sendable
    /// The concrete type returned by the result-builder `body` property.
    associatedtype Body: Interactor

    /// A declarative description of this interactor constructed with ``InteractorBuilder``.
    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    /// Processes an action by mutating state and returning an emission.
    ///
    /// - Parameters:
    ///   - state: The current state, passed as `inout` for mutation.
    ///   - action: The action to process.
    /// - Returns: An ``Emission`` describing actions to emit.
    func interact(state: inout DomainState, action: Action) -> Emission<Action>
}

extension Interactor where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension Interactor where Body: Interactor<DomainState, Action> {
    /// The default implementation forwards to the `body` interactor.
    public func interact(state: inout DomainState, action: Action) -> Emission<Action> {
        body.interact(state: &state, action: action)
    }
}

/// A convenience alias that exposes the `DomainState` and `Action` associated types of an
/// ``Interactor``.
///
/// Use this alias in `body` return types:
/// ```swift
/// var body: some InteractorOf<Self> {
///     Interact(initialValue: MyState()) { ... }
/// }
/// ```
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
public struct AnyInteractor<State: Sendable, Action: Sendable>: Interactor, Sendable {
    private let interactFunc: @Sendable (inout State, Action) -> Emission<Action>

    public init<I: Interactor & Sendable>(_ base: I) where I.DomainState == State, I.Action == Action {
        self.interactFunc = { state, action in base.interact(state: &state, action: action) }
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(state: inout State, action: Action) -> Emission<Action> {
        interactFunc(&state, action)
    }
}

extension Interactor where Self: Sendable {
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

/// A wrapper that marks any interactor as `@unchecked Sendable`.
///
/// Use this when you need to erase an interactor that isn't `Sendable` but you
/// know it's safe to use across concurrency boundaries (e.g., it only captures
/// `@MainActor`-isolated closures that will be called on the main actor).
public struct UncheckedSendableInteractor<I: Interactor>: Interactor, @unchecked Sendable {
    public let wrapped: I

    public init(_ wrapped: I) {
        self.wrapped = wrapped
    }

    public var body: some Interactor<I.DomainState, I.Action> { self }

    public func interact(state: inout I.DomainState, action: I.Action) -> Emission<I.Action> {
        wrapped.interact(state: &state, action: action)
    }
}

extension Interactor {
    /// Wraps this interactor in an unchecked sendable wrapper, allowing it to be erased.
    ///
    /// Use this when you need to erase an interactor that isn't `Sendable` but you
    /// know it's safe to use across concurrency boundaries.
    public func uncheckedSendable() -> UncheckedSendableInteractor<Self> {
        UncheckedSendableInteractor(self)
    }

    /// Erases this interactor to `AnyInteractor` using an unchecked sendable wrapper.
    ///
    /// This is a convenience that combines `uncheckedSendable()` and `eraseToAnyInteractor()`.
    public func eraseToAnyInteractorUnchecked() -> AnyInteractor<DomainState, Action> {
        UncheckedSendableInteractor(self).eraseToAnyInteractor()
    }
}
