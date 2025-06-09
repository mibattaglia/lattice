import Combine
import Foundation

public struct EmptyInteractor<State, Action>: Interactor {
    public typealias DomainState = State
    public typealias Action = Action

    public init() {}

    public var body: some InteractorOf<Self> { self }

    public func interact(
        _ upstream: AnyPublisher<Action, Never>
    ) -> AnyPublisher<State, Never> {
        Empty().eraseToAnyPublisher()
    }
}
