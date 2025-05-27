import Combine
import Foundation

public protocol Interactor<DomainState, Action> {
    associatedtype DomainState
    associatedtype Action
    associatedtype Body: Interactor

    @InteractorBuilder<DomainState, Action>
    var body: Body { get }

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
    public func interact(
        _ upstream: AnyPublisher<Action, Never>
    ) -> AnyPublisher<DomainState, Never> {
        self.body.interact(upstream)
    }
}

public typealias InteractorOf<I: Interactor> = Interactor<I.DomainState, I.Action>

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
