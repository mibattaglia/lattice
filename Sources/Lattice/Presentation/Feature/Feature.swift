import Foundation

/// A type-level descriptor for a Lattice feature.
///
/// This protocol enables API surfaces that can be expressed in terms of a single
/// generic `F`, such as `ViewModel<F>`.
public protocol FeatureProtocol {
    associatedtype Action: Sendable
    associatedtype State: FeatureState & Sendable
    var interactor: AnyInteractor<State, Action> { get }
    /// Content equality. Gates content-equal wholesale root replacement in `ViewModel` and
    /// drives `TestViewModel` assertions. `nil` when the state has no usable equality.
    var areStatesEqual: ((State, State) -> Bool)? { get }
}

/// Bundles the interactor of a feature with its state equality.
///
/// A `Feature` is the shared configuration unit for both production and tests:
///
/// - ``ViewModel`` runs the interactor and uses ``areStatesEqual`` to keep the current state, and
///   every observer registered on it, when an action replaces the state with equal content.
/// - ``TestViewModel`` runs the same interactor and compares states with the same equality.
///
/// ```swift
/// let viewModel = ViewModel(
///     initialState: CounterState(),
///     feature: Feature(interactor: CounterInteractor())
/// )
/// ```
///
/// When the state is `Equatable`, `Feature(interactor:)` compares states with `==`. Pass
/// `areStatesEqual:` for a custom comparison or a state that is not `Equatable`.
public struct Feature<Action: Sendable, State: FeatureState & Sendable>: FeatureProtocol {
    public let interactor: AnyInteractor<State, Action>
    public let areStatesEqual: ((State, State) -> Bool)?

    public init<I: Interactor & Sendable>(interactor: I, areStatesEqual: ((State, State) -> Bool)?)
    where I.State == State, I.Action == Action {
        self.interactor = interactor.eraseToAnyInteractor()
        self.areStatesEqual = areStatesEqual
    }

    public init<I: Interactor & Sendable>(interactor: I) where I.State == State, I.Action == Action {
        self.init(interactor: interactor, areStatesEqual: nil)
    }
}

extension Feature where State: Equatable {
    public init<I: Interactor & Sendable>(interactor: I) where I.State == State, I.Action == Action {
        self.init(interactor: interactor, areStatesEqual: { $0 == $1 })
    }
}
