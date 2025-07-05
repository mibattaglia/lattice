import Combine
import Foundation

/// A type that transforms a stream of **actions** into a stream of **domain state**.
///
/// An `Interactor` is the core unit of a feature's system. It plays a role similar to a
/// "reducer" in other architectures, but instead of synchronously returning new state it returns
/// a _publisher_ of state values. This makes it trivial to express asynchronous work (such as
/// network requests, timers, etc.) and to merge the results of multiple `Interactor`s together.
///
/// ### Declaring an interactor
/// ```swift
/// @Interactor<State, Action>
/// struct CounterInteractor {
///   var body: some InteractorOf<Self> {
///     Interact(initialValue: .loading) { domainState, action in
///         ...
///     }
///   }
/// }
/// ```
/// In the vast majority of cases you only implement the `body` property and let the compiler
/// **infer its concrete return type** via Swift's result-builder machinery; you do **not** need to
/// explicitly declare `typealias Body`.
public protocol Interactor<DomainState, Action> {
    /// The type of state produced downstream.
    associatedtype DomainState
    /// The type of actions received upstream.
    associatedtype Action
    /// The "body" type returned by the result-builder.
    associatedtype Body: Interactor

    /// A declarative description of this interactor constructed with ``InteractorBuilder``.
    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    /// Transforms the upstream action publisher into a publisher of domain state.
    ///
    /// In most cases, you only need to implement ``body`` in an Interactor to handle your feature's logic.
    /// If however, you find you need finer control over the consumption and publishing of events, you can implement
    /// ``interact(_:)-6azej`` and manually publish DomainState downstream:
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> { self }
    ///
    /// func interact(_ upstream: AnyPublisher<Action, Never> -> AnyPublisher<DomainState, Never> {
    ///     upstream.map { action in
    ///         /// complex event stream logic
    ///     }
    ///     .eraseToAnyPublisher()
    /// }
    /// ```
    ///
    /// > Important: this method, if implemented, will take precedence over an implementation in ``body``.
    ///
    /// - Parameter upstream: A publisher of ``Action`` values coming from the view layer.
    /// - Returns: A publisher that emits new `DomainState` values.
    func interact(
        _ upstream: AnyPublisher<Action, Never>
    ) -> AnyPublisher<DomainState, Never>
}

extension Interactor where Body.DomainState == Never {
    public var body: Body {
        fatalError(
            """
            '\(Self.self)' has no body.
            """
        )
    }
}

extension Interactor where Body: Interactor<DomainState, Action> {
    /// The default implementation forwards to the `body` interactor.
    public func interact(
        _ upstream: AnyPublisher<Action, Never>
    ) -> AnyPublisher<DomainState, Never> {
        self.body.interact(upstream)
    }
}

/// A convenience alias that exposes the `DomainState` and `Action` associated types of an
/// ``Interactor``.
public typealias InteractorOf<I: Interactor> = Interactor<I.DomainState, I.Action>

/// A type-erased wrapper of any ``Interactor``.
public struct AnyInteractor<State, Action>: Interactor {
    private let interactFunc: (AnyPublisher<Action, Never>) -> AnyPublisher<State, Never>

    public init<I: Interactor>(
        _ base: I
    ) where I.DomainState == State, I.Action == Action {
        self.interactFunc = base.interact(_:)
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(_ upstream: AnyPublisher<Action, Never>) -> AnyPublisher<State, Never> {
        interactFunc(upstream)
    }
}

extension Interactor {
    public func eraseToAnyInteractor() -> AnyInteractor<DomainState, Action> {
        AnyInteractor(self)
    }
}
