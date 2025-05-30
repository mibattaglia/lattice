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

extension ViewStateReducer {
    public static func build(
        _ block: @escaping (DomainState) -> ViewState
    ) -> BuildViewState<DomainState, ViewState> {
        BuildViewState(reducerBlock: block)
    }
}

public typealias ViewStateReducerOf<V: ViewStateReducer> = ViewStateReducer<V.DomainState, V.ViewState>

public struct AnyViewStateReducer<DomainState, ViewState>: ViewStateReducer {
    private let reduceFunc: (AnyPublisher<DomainState, Never>) -> AnyPublisher<ViewState, Never>

    init<VS: ViewStateReducer>(_ base: VS)
    where VS.DomainState == DomainState, VS.ViewState == ViewState {
        self.reduceFunc = base.reduce(_:)
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(
        _ upstream: AnyPublisher<DomainState, Never>
    ) -> AnyPublisher<ViewState, Never> {
        reduceFunc(upstream)
    }
}

extension ViewStateReducer {
    public func eraseToAnyReducer() -> AnyViewStateReducer<DomainState, ViewState> {
        AnyViewStateReducer(self)
    }
}
