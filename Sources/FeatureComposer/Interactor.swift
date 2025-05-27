import Combine
import Foundation

public protocol Interactor<State, Action> {
    associatedtype State
    associatedtype Action
    associatedtype Body: Interactor

    @InteractorBuilder<State, Action>
    var body: Body { get }

    func interact(
        _ upstream: AnyPublisher<Action, Never>
    ) -> AnyPublisher<State, Never>
}

extension Interactor where Body.State == Never {
    public var body: Body {
        fatalError(
            """
            '\(Self.self)' has no body.
            """
        )
    }
}

extension Interactor where Body: Interactor<State, Action> {
    public func interact(
        _ upstream: AnyPublisher<Action, Never>
    ) -> AnyPublisher<State, Never> {
        self.body.interact(upstream)
    }
}

public typealias InteractorOf<I: Interactor> = Interactor<I.State, I.Action>

public struct AnyInteractor<State, Action>: Interactor {
    private let interactFunc: (AnyPublisher<Action, Never>) -> AnyPublisher<State, Never>

    public init<I: Interactor>(
        _ base: I
    ) where I.State == State, I.Action == Action {
        self.interactFunc = base.interact(_:)
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(_ upstream: AnyPublisher<Action, Never>) -> AnyPublisher<State, Never> {
        interactFunc(upstream)
    }
}

extension Interactor {
    public func eraseToAnyInteractor() -> AnyInteractor<State, Action> {
        AnyInteractor(self)
    }
}
