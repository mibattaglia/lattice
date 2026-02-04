import Foundation

/// A type that transforms domain **state** into **view state** via in-place mutation.
///
/// `ViewStateReducer` mutates an existing view state based on domain state, preserving
/// `_$id` stability for `@ObservableState` types. This enables efficient SwiftUI observation
/// where only changed properties trigger view updates.
///
/// ## Purpose
///
/// Separating domain state from view state provides several benefits:
///
/// - **Separation of concerns**: Domain logic stays independent of UI requirements
/// - **Testability**: View state transformations can be tested in isolation
/// - **Performance**: Only view-relevant data is observed by SwiftUI
/// - **Observation stability**: `_$id` is preserved across reduce calls
///
/// ## Usage
///
/// Use the `@ViewStateReducer` macro for a concise declaration:
///
/// ```swift
/// @ViewStateReducer<CounterDomainState, CounterViewState>
/// struct CounterViewStateReducer: Sendable {
///     var body: some ViewStateReducerOf<Self> {
///         BuildViewState { domainState, viewState in
///             viewState.count = domainState.count
///             viewState.displayText = "Count: \(domainState.count)"
///             viewState.canDecrement = domainState.count > 0
///         }
///     }
/// }
/// ```
///
/// ## Integration
///
/// Connect the reducer to a view model via `#subscribe`:
///
/// ```swift
/// #subscribe { builder in
///     builder
///         .interactor(interactor)
///         .viewStateReducer(reducer)
/// }
/// ```
public protocol ViewStateReducer<DomainState, ViewState> {
    /// The type of DomainState consumed upstream. Usually fed into the ViewStateReducer
    /// via an ``Interactor`` and a ``subscribe(_:)`` block.
    associatedtype DomainState
    /// The type of ViewState published downstream. Usually used as "rendering instructions" for a
    /// UI component.
    associatedtype ViewState
    associatedtype Body: ViewStateReducer

    /// A declarative description of this ViewStateReducer that consumes DomainState and mutates ViewState.
    ///
    /// **Note:** ``ViewStateReducerBuilder`` is provided to allow a familiar API to the one exposed
    /// in ``Interactor``. Composition of ViewStateReducers is currently not supported.
    @ViewStateReducerBuilder<DomainState, ViewState>
    var body: Body { get }

    /// Mutates view state in-place based on domain state.
    func reduce(_ domainState: DomainState, into viewState: inout ViewState)
}

extension ViewStateReducer where Body.DomainState == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no body.")
    }
}

extension ViewStateReducer {
    public static func buildViewState(
        reducerBlock: @escaping (DomainState, inout ViewState) -> Void
    ) -> BuildViewState<DomainState, ViewState> {
        BuildViewState(reducerBlock: reducerBlock)
    }
}

extension ViewStateReducer where Body: ViewStateReducer<DomainState, ViewState> {
    public func reduce(_ domainState: DomainState, into viewState: inout ViewState) {
        self.body.reduce(domainState, into: &viewState)
    }
}

public typealias ViewStateReducerOf<V: ViewStateReducer> = ViewStateReducer<V.DomainState, V.ViewState>

/// A type-erased wrapper around any ``ViewStateReducer``.
public struct AnyViewStateReducer<DomainState, ViewState>: ViewStateReducer, Sendable {
    private let reduceFunc: @Sendable (DomainState, inout ViewState) -> Void

    public init<VS: ViewStateReducer & Sendable>(_ base: VS)
    where VS.DomainState == DomainState, VS.ViewState == ViewState {
        self.reduceFunc = { domainState, viewState in
            base.reduce(domainState, into: &viewState)
        }
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(_ domainState: DomainState, into viewState: inout ViewState) {
        reduceFunc(domainState, &viewState)
    }
}

extension ViewStateReducer where Self: Sendable {
    /// Returns a type-erased wrapper of `self`.
    public func eraseToAnyReducer() -> AnyViewStateReducer<DomainState, ViewState> {
        AnyViewStateReducer(self)
    }
}
