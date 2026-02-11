import Foundation

/// Bundles the architecture stack for a feature.
///
/// Use a `Feature` to initialize a `ViewModel` with a single argument:
///
/// ```swift
/// let feature = Feature(
///     interactor: CounterInteractor(),
///     reducer: CounterViewStateReducer()
/// )
/// let viewModel = ViewModel(
///     initialDomainState: CounterDomainState(count: 0),
///     feature: feature
/// )
/// ```
///
/// When `DomainState == ViewState`, you can omit the reducer:
///
/// ```swift
/// let feature = Feature(interactor: CounterInteractor())
/// let viewModel = ViewModel(
///     initialDomainState: CounterState(count: 0),
///     feature: feature
/// )
/// ```
public struct Feature<Action, DomainState, ViewState>
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState {
    public let interactor: AnyInteractor<DomainState, Action>
    public let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    public let makeInitialViewState: (DomainState) -> ViewState
    public let areStatesEqual: (DomainState, DomainState) -> Bool

    public init<I, R>(
        interactor: I,
        reducer: R,
        areStatesEqual: @escaping (DomainState, DomainState) -> Bool
    )
    where
        I: Interactor & Sendable,
        R: ViewStateReducer & Sendable,
        I.DomainState == DomainState, I.Action == Action,
        R.DomainState == DomainState, R.ViewState == ViewState
    {
        self.interactor = interactor.eraseToAnyInteractor()
        self.viewStateReducer = reducer.eraseToAnyReducer()
        self.makeInitialViewState = { reducer.initialViewState(for: $0) }
        self.areStatesEqual = areStatesEqual
    }

    public init<I>(
        interactor: I,
        areStatesEqual: @escaping (DomainState, DomainState) -> Bool
    )
    where
        I: Interactor & Sendable,
        I.DomainState == DomainState, I.Action == Action,
        DomainState == ViewState
    {
        self.interactor = interactor.eraseToAnyInteractor()
        self.viewStateReducer = BuildViewState { domainState, viewState in
            viewState = domainState
        }.eraseToAnyReducer()
        self.makeInitialViewState = { $0 }
        self.areStatesEqual = areStatesEqual
    }
}

extension Feature where DomainState: Equatable {
    public init<I, R>(
        interactor: I,
        reducer: R
    )
    where
        I: Interactor & Sendable,
        R: ViewStateReducer & Sendable,
        I.DomainState == DomainState, I.Action == Action,
        R.DomainState == DomainState, R.ViewState == ViewState
    {
        self.init(interactor: interactor, reducer: reducer, areStatesEqual: { $0 == $1 })
    }

    public init<I>(
        interactor: I
    )
    where
        I: Interactor & Sendable,
        I.DomainState == DomainState, I.Action == Action,
        DomainState == ViewState
    {
        self.init(interactor: interactor, areStatesEqual: { $0 == $1 })
    }
}
