import Combine
import Foundation

public protocol Interactor<State, Action> {
    associatedtype State: Equatable
    associatedtype Action
    associatedtype Body: Interactor

    @InteractorBuilder<State, Action>
    var body: Body { get }

    func interact(
        _ upstream: AnyPublisher<Action, Never>
    ) -> AnyPublisher<InteractionResult<State>, Never>
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
    ) -> AnyPublisher<InteractionResult<State>, Never> {
        self.body.interact(upstream)
    }
}

public typealias InteractorOf<I: Interactor> = Interactor<I.State, I.Action>
public typealias InteractOver<I: Interactor> = Interact<I.State, I.Action>
