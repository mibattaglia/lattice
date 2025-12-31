import AsyncAlgorithms
import Foundation

/// A type that transforms a stream of **actions** into a stream of **domain state**.
public protocol Interactor<DomainState, Action> {
    associatedtype DomainState: Sendable
    associatedtype Action: Sendable
    associatedtype Body: Interactor

    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

    func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState>
}

extension Interactor where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension Interactor where Body: Interactor<DomainState, Action> {
    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState> {
        self.body.interact(upstream)
    }
}

public typealias InteractorOf<I: Interactor> = Interactor<I.DomainState, I.Action>

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

