import AsyncAlgorithms
import Foundation

/// A type that transforms a stream of **actions** into a stream of **domain state**.
///
/// An `Interactor` is the core unit of a feature's business logic. It plays a role similar to a
/// "reducer" in other architectures, but instead of synchronously returning new state it returns
/// an `AsyncStream` of state values. This makes it trivial to express asynchronous work (such as
/// network requests, timers, etc.) and to merge the results of multiple `Interactor`s together.
///
/// ## Declaring an Interactor
///
/// Use the `@Interactor` macro for a concise declaration:
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
/// In most cases you only implement the `body` property and let the compiler infer its concrete
/// return type via Swift's result-builder machinery.
///
/// ## Custom Implementation
///
/// For advanced scenarios requiring direct stream control, implement `interact(_:)` directly:
///
/// ```swift
/// func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState> {
///     AsyncStream { continuation in
///         Task {
///             for await action in upstream {
///                 // Custom stream handling
///             }
///             continuation.finish()
///         }
///     }
/// }
/// ```
///
/// - Note: Custom `interact(_:)` implementations take precedence over `body`.
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

    /// Transforms the upstream action stream into a stream of domain state.
    ///
    /// - Parameter upstream: An `AsyncStream` of actions coming from the view layer.
    /// - Returns: An `AsyncStream` that emits new `DomainState` values.
    func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState>
}

extension Interactor where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension Interactor where Body: Interactor<DomainState, Action> {
    /// The default implementation forwards to the `body` interactor.
    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState> {
        self.body.interact(upstream)
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
    private let interactFunc: @Sendable (AsyncStream<Action>) -> AsyncStream<State>

    public init<I: Interactor & Sendable>(_ base: I) where I.DomainState == State, I.Action == Action {
        self.interactFunc = { upstream in base.interact(upstream) }
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        interactFunc(upstream)
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

    public func interact(_ upstream: AsyncStream<I.Action>) -> AsyncStream<I.DomainState> {
        wrapped.interact(upstream)
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

