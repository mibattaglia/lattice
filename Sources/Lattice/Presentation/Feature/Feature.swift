import Foundation

/// A type-level descriptor for a Lattice feature.
///
/// This protocol enables API surfaces that can be expressed in terms of a single
/// generic `F`, pairing a feature-state type with an erased interactor.
public protocol FeatureProtocol {
    associatedtype State: FeatureStateProtocol
    associatedtype Action

    var interactor: AnyInteractor<State, Action> { get }
}

/// Bundles a feature's state type with an erased interactor.
///
/// A `Feature` is a slim convenience for passing a feature's configuration as one value:
///
/// ```swift
/// let feature = Feature<CounterState, CounterAction>(interactor: CounterInteractor())
/// let viewModel = ViewModel(initialState: CounterState(), feature: feature)
/// ```
///
/// A ``ViewModel`` can equally be built directly via `init(initialState:interactor:)`.
public struct Feature<State: FeatureStateProtocol, Action>: FeatureProtocol {
    public let interactor: AnyInteractor<State, Action>

    public init<I: Interactor>(interactor: I)
    where I.DomainState == State, I.Action == Action {
        self.interactor = interactor.eraseToAnyInteractor()
    }
}
