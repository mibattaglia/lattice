import Combine
import Foundation

/// A reusable abstraction for state-action transformation
public struct Interact<State: Equatable, Action>: Interactor {
    private let defaultValue: State
    private let handler: (inout State, Action) async -> InteractionResult<State>

    public init(
        defaultValue: State,
        handler: @escaping (inout State, Action) async -> InteractionResult<State>
    ) {
        self.defaultValue = defaultValue
        self.handler = handler
    }

    public var body: some Interactor<State, Action> {
        self
    }
    
    public func interact(_ upstream: AnyPublisher<Action, Never>) -> AnyPublisher<InteractionResult<State>, Never> {
        Empty().eraseToAnyPublisher()
    }
}
