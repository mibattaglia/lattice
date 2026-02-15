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
public struct BuildViewState<DomainState, ViewState>: ViewStateReducer, @unchecked Sendable {
    private let initial: (DomainState) -> ViewState
    private let reducerBlock: (DomainState, inout ViewState) -> Void

    public func initialViewState(for domainState: DomainState) -> ViewState {
        initial(domainState)
    }

    public init(
        initial: @escaping (DomainState) -> ViewState,
        reducerBlock: @escaping (DomainState, inout ViewState) -> Void
    ) {
        self.initial = initial
        self.reducerBlock = reducerBlock
    }

    public init(reducerBlock: @escaping (DomainState, inout ViewState) -> Void) {
        self.initial = { _ in
            fatalError("Provide initialViewState(for:) on the containing ViewStateReducer.")
        }
        self.reducerBlock = reducerBlock
    }

    public var body: some ViewStateReducer<DomainState, ViewState> { self }

    public func reduce(_ domainState: DomainState, into viewState: inout ViewState) {
        reducerBlock(domainState, &viewState)
    }
}

extension BuildViewState where ViewState: DefaultValueProvider {
    public init(reducerBlock: @escaping (DomainState, inout ViewState) -> Void) {
        self.init(initial: { _ in .defaultValue }, reducerBlock: reducerBlock)
    }
}
