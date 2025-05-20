import Combine
import Foundation

/// A reusable abstraction for state-action transformation
public struct Interact<State: Equatable, Action>: Interactor {
    private let initialValue: State
    private let handler: (inout State, Action) -> Emission<State>

    public init(
        initialValue: State,
        handler: @escaping (inout State, Action) -> Emission<State>
    ) {
        self.initialValue = initialValue
        self.handler = handler
    }

    public var body: some Interactor<State, Action> {
        self
    }
    
    public func interact(_ upstream: AnyPublisher<Action, Never>) -> AnyPublisher<State, Never> {
        upstream
            .feedback(initialState: initialValue, handler: handler)
            .prepend(initialValue)
            .eraseToAnyPublisher()
    }
}
