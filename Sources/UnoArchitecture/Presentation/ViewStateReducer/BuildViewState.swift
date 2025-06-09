import Combine
import Foundation

public struct BuildViewState<DomainState, ViewState>: ViewStateReducer {
    private let reducerBlock: (DomainState) -> ViewState

    public init(reducerBlock: @escaping (DomainState) -> ViewState) {
        self.reducerBlock = reducerBlock
    }

    public var body: some ViewStateReducer<DomainState, ViewState> {
        self
    }

    public func reduce(
        _ upstream: AnyPublisher<DomainState, Never>
    ) -> AnyPublisher<ViewState, Never> {
        upstream
            .map(reducerBlock)
            .eraseToAnyPublisher()
    }
}
