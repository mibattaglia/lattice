import Combine
import Foundation

public protocol ViewStateReducer<DomainState, ViewState> {
    associatedtype DomainState
    associatedtype ViewState
    associatedtype Body: ViewStateReducer

    @ViewStateReducerBuilder<DomainState, ViewState>
    var body: Body { get }

    func reduce(
        _ upstream: AnyPublisher<DomainState, Never>
    ) -> AnyPublisher<ViewState, Never>
}

extension ViewStateReducer where Body.DomainState == Never {
    public var body: Body {
        fatalError(
            """
            '\(Self.self)' has no body.
            """
        )
    }
}

extension ViewStateReducer where Body: ViewStateReducer<DomainState, ViewState> {
    public func reduce(
        _ upstream: AnyPublisher<DomainState, Never>
    ) -> AnyPublisher<ViewState, Never> {
        self.body.reduce(upstream)
    }
}

public typealias ViewStateReducerOf<V: ViewStateReducer> = ViewStateReducer<V.DomainState, V.ViewState>
