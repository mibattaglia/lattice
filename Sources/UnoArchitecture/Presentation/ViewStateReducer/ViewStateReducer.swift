import Combine
import Foundation

/// A type that transforms a publisher of domain **state** into a publisher of **view state**.
///
/// ``ViewStateReducer`` is a **stateless** transformer. Its sole purpose is to consume
/// complex `DomainState` and simplify (or _reduce_) it into simpler state for another component to use.
/// Usually, this means generating "rendering instructions" for a UI component.
///
/// Feature state accumulation should be handled in an ``Interactor`` and then fed into a ViewStateReducer
/// via a ``subscribe(_:)`` block in a ``ViewModel``.
public protocol ViewStateReducer<DomainState, ViewState> {
    /// The type of DomainState consumed upstream. Usually fed into the ViewStateReducer
    /// via an ``Interactor`` and a ``subscribe(_:)`` block.
    associatedtype DomainState
    /// The type of ViewState published downstream. Usually used as "rendering instructions" for a
    /// UI component.
    associatedtype ViewState
    associatedtype Body: ViewStateReducer

    /// A declarative description of this ViewStateReducer that consumes DomainState and returns ViewState.
    ///
    /// **Note:** ``ViewStateReducerBuilder`` is provided to allow a familiar API to the one exposed
    /// in ``Interactor``. Composition of ViewStateReducers is currently not supported.
    @ViewStateReducerBuilder<DomainState, ViewState>
    var body: Body { get }

    /// Transforms the upstream publisher of `DomainState` into a downstream publisher of `ViewState`.
    ///
    /// > Important: do not implement this method directly. It is synthesized via conformance to this protocol.
    ///
    /// - Parameter upstream: A publisher of ``Action`` values coming from the view layer.
    /// - Returns: A publisher that emits new `DomainState` values.
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

extension ViewStateReducer {
    public static func buildViewState(
        reducerBlock: @escaping (DomainState) -> ViewState
    ) -> BuildViewState<DomainState, ViewState> {
        BuildViewState(reducerBlock: reducerBlock)
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

/// A type-erased wrapper around any ``ViewStateReducer``.
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
    /// Returns a type-erased wrapper of `self`.
    public func eraseToAnyReducer() -> AnyViewStateReducer<DomainState, ViewState> {
        AnyViewStateReducer(self)
    }
}
