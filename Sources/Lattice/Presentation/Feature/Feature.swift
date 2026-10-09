import Foundation

/// A type-level descriptor for a Lattice feature.
///
/// This protocol enables API surfaces that can be expressed in terms of a single
/// generic `F`, such as `ViewModel<F>`.
public protocol FeatureProtocol {
    associatedtype Action: Sendable
    associatedtype DomainState: Sendable
    associatedtype ViewState

    var interactor: AnyInteractor<DomainState, Action> { get }
    var viewStateReducer: AnyViewStateReducer<DomainState, ViewState> { get }
    var makeInitialViewState: (DomainState) -> ViewState { get }
    var areStatesEqual: (DomainState, DomainState) -> Bool { get }
}

/// Bundles the architecture stack for a feature.
///
/// A `Feature` is the shared configuration unit for both production and tests:
///
/// - ``ViewModel`` uses it to drive SwiftUI-facing execution and `viewState` updates.
/// - ``TestViewModel`` uses the same interactor and equality rules for step-wise domain-state assertions.
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
where Action: Sendable, DomainState: Sendable {
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
        R.DomainState == DomainState, R.ViewState == ViewState,
        ViewState: ObservableState
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
        DomainState == ViewState, ViewState: ObservableState
    {
        self.interactor = interactor.eraseToAnyInteractor()
        self.viewStateReducer = BuildViewState(
            initial: { $0 },
            reducerBlock: { domainState, viewState in
                viewState = domainState
            }
        ).eraseToAnyReducer()
        self.makeInitialViewState = { $0 }
        self.areStatesEqual = areStatesEqual
    }
}

extension Feature: FeatureProtocol {}

extension Feature where DomainState: Equatable {
    public init<I, R>(
        interactor: I,
        reducer: R
    )
    where
        I: Interactor & Sendable,
        R: ViewStateReducer & Sendable,
        I.DomainState == DomainState, I.Action == Action,
        R.DomainState == DomainState, R.ViewState == ViewState,
        ViewState: ObservableState
    {
        self.init(interactor: interactor, reducer: reducer, areStatesEqual: { $0 == $1 })
    }

    public init<I>(
        interactor: I
    )
    where
        I: Interactor & Sendable,
        I.DomainState == DomainState, I.Action == Action,
        DomainState == ViewState, ViewState: ObservableState
    {
        self.init(interactor: interactor, areStatesEqual: { $0 == $1 })
    }
}

/// Temporary third-generic marker for the T1 integrated proof. This carries no
/// presentation state and is removed with the legacy Feature API in T3/T6.
public struct _FeatureStatePresentation: Sendable {
    init() {}
}

extension Feature where DomainState: FeatureStateProtocol, ViewState == _FeatureStatePresentation {
    public init<I>(
        interactor: I,
        areStatesEqual: @escaping (DomainState, DomainState) -> Bool
    ) where I: Interactor & Sendable, I.DomainState == DomainState, I.Action == Action {
        self.interactor = interactor.eraseToAnyInteractor()
        self.viewStateReducer = BuildViewState<DomainState, ViewState>(
            initial: { _ in _FeatureStatePresentation() }, reducerBlock: { _, _ in }
        ).eraseToAnyReducer()
        self.makeInitialViewState = { _ in _FeatureStatePresentation() }
        // Kept on Feature for TestViewModel. Tracked production never consults it.
        self.areStatesEqual = areStatesEqual
    }
}

extension Feature where DomainState: FeatureStateProtocol & Equatable, ViewState == _FeatureStatePresentation {
    public init<I>(interactor: I)
    where I: Interactor & Sendable, I.DomainState == DomainState, I.Action == Action {
        self.init(interactor: interactor, areStatesEqual: { $0 == $1 })
    }
}
