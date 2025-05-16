import Combine
import Foundation

/// A reusable abstraction for state-action transformation
public struct Interact<State: Equatable, Action>: Interactor {
    private let defaultValue: State?
    private let handler: (inout State, Action) -> InteractionResult<State>

    public init(
        defaultValue: State? = nil,
        handler: @escaping (inout State, Action) -> InteractionResult<State>
    ) {
        self.defaultValue = defaultValue
        self.handler = handler
    }

    public var body: some Interactor<State, Action> {
        self
    }

//    public func transform(state: inout State, action: Action) -> InteractionResult<State> {
//        handler(&state, action)
//    }
    public func interact(_ upstream: AnyPublisher<Action, Never>) -> AnyPublisher<InteractionResult<State>, Never> {
        upstream
            .scan(defaultValue) { state, action in
                guard let state else { return state }
                var newState = state
                handler(&newState, action)
                return newState
            }
            .compactMap { $0 }
            .map { _ in .state }
            .eraseToAnyPublisher()
    }
}
