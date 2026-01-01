import Foundation

/// A convenience ``ViewStateReducer`` that mutates `ViewState` based on `DomainState`.
///
/// You'll typically use this directly in the body of a ``ViewStateReducer``:
///
/// ``` swift
/// @ViewStateReducer<DomainState, ViewState>
/// struct MyViewStateReducer {
///     var body: some ViewStateReducerOf<Self> {
///         BuildViewState { domainState, viewState in
///             viewState.property = domainState.value
///         }
///     }
/// }
/// ```
public struct BuildViewState<DomainState, ViewState>: ViewStateReducer {
    private let reducerBlock: (DomainState, inout ViewState) -> Void

    public init(reducerBlock: @escaping (DomainState, inout ViewState) -> Void) {
        self.reducerBlock = reducerBlock
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(_ domainState: DomainState, into viewState: inout ViewState) {
        reducerBlock(domainState, &viewState)
    }
}
