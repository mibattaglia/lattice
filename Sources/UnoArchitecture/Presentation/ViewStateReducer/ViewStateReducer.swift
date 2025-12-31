import Foundation

/// A type that transforms domain **state** into **view state**.
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

    /// Transforms domain state into view state synchronously.
    func reduce(_ domainState: DomainState) -> ViewState
}

extension ViewStateReducer where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
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
    public func reduce(_ domainState: DomainState) -> ViewState {
        self.body.reduce(domainState)
    }
}

public typealias ViewStateReducerOf<V: ViewStateReducer> = ViewStateReducer<V.DomainState, V.ViewState>

/// A type-erased wrapper around any ``ViewStateReducer``.
public struct AnyViewStateReducer<DomainState, ViewState>: ViewStateReducer, Sendable {
    private let reduceFunc: @Sendable (DomainState) -> ViewState

    public init<VS: ViewStateReducer & Sendable>(_ base: VS)
    where VS.DomainState == DomainState, VS.ViewState == ViewState {
        self.reduceFunc = { base.reduce($0) }
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(_ domainState: DomainState) -> ViewState {
        reduceFunc(domainState)
    }
}

extension ViewStateReducer where Self: Sendable {
    /// Returns a type-erased wrapper of `self`.
    public func eraseToAnyReducer() -> AnyViewStateReducer<DomainState, ViewState> {
        AnyViewStateReducer(self)
    }
}
