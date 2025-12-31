import Foundation

/// A convenience ``ViewStateReducer`` that maps `DomainState` directly to `ViewState`.
///
/// You'll typically use this directly in the body of a ``ViewStateReducer``:
///
/// ``` swift
/// @ViewStateReducer<DomainState, ViewState>
/// struct MyViewStateReducer {
///     var body: some ViewStateReducerOf<Self> {
///         BuildViewState { domainState in
///             /// transformation logic
///         }
///     }
/// }
/// ```
public struct BuildViewState<DomainState, ViewState>: ViewStateReducer {
    private let reducerBlock: (DomainState) -> ViewState

    public init(reducerBlock: @escaping (DomainState) -> ViewState) {
        self.reducerBlock = reducerBlock
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(_ domainState: DomainState) -> ViewState {
        reducerBlock(domainState)
    }
}
