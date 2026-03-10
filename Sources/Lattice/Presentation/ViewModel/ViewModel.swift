import Observation
import SwiftUI

@MainActor
protocol _ViewModel {
    associatedtype ViewState: ObservableState

    var viewState: ViewState { get }
}

/// A generic class that binds a SwiftUI view to your domain/business logic.
///
/// `ViewModel` connects a `Feature` to SwiftUI. Views send user events through
/// ``sendViewEvent(_:)``, and render from ``viewState``.
///
/// ## Overview
///
/// The data flow is unidirectional:
///
/// 1. View calls `sendViewEvent(_:)` with user actions
/// 2. The ``Interactor`` processes the action synchronously and returns an ``Emission``
/// 3. State mutations are applied immediately
/// 4. The ``ViewStateReducer`` transforms domain state to view state
/// 5. Any async effects from the emission are spawned as tasks
/// 6. View observes `viewState` changes and re-renders
///
/// ## Initialization
///
/// Create a view model by providing the initial domain state and a `Feature`:
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
/// ## Key Components
///
/// - ``viewState``: Observable state used by SwiftUI rendering.
/// - ``sendViewEvent(_:)``: Dispatches actions and returns an ``EventTask`` for any spawned effects.
///
/// ## SwiftUI Integration
///
/// Use `@State` to hold the view model:
///
/// ```swift
/// struct CounterView: View {
///     @State var viewModel = ViewModel(
///         initialDomainState: CounterState(count: 0),
///         feature: Feature(interactor: CounterInteractor())
///     )
///
///     var body: some View {
///         Text("Count: \(viewModel.count)")
///         Button("Increment") {
///             viewModel.sendViewEvent(.increment)
///         }
///     }
/// }
/// ```
///
/// ## Awaiting Effects
///
/// Use ``EventTask/finish()`` to await effect completion when needed:
///
/// ```swift
/// .refreshable {
///     await viewModel.sendViewEvent(.refresh).finish()
/// }
/// ```
@dynamicMemberLookup
@MainActor
public final class ViewModel<F: FeatureProtocol>: Observable, _ViewModel {
    public typealias Action = F.Action
    public typealias DomainState = F.DomainState
    public typealias ViewState = F.ViewState

    private var _viewState: ViewState
    private let runtime: FeatureRuntime<DomainState, Action>

    private let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    private let areStatesEqual: (_ lhs: DomainState, _ rhs: DomainState) -> Bool

    private let _$observationRegistrar = ObservationRegistrar()

    /// Creates a ViewModel for a concrete feature.
    ///
    /// - Parameters:
    ///   - initialDomainState: The initial domain state value.
    ///   - feature: The feature bundle containing interactor/reducer wiring.
    public convenience init(
        initialDomainState: DomainState,
        feature: F
    ) {
        self.init(
            initialDomainState: initialDomainState,
            initialViewState: feature.makeInitialViewState(initialDomainState),
            interactor: feature.interactor,
            viewStateReducer: feature.viewStateReducer,
            areStatesEqual: feature.areStatesEqual
        )
    }

    init(
        initialDomainState: DomainState,
        initialViewState: @autoclosure () -> ViewState,
        interactor: AnyInteractor<DomainState, Action>,
        viewStateReducer: AnyViewStateReducer<DomainState, ViewState>,
        areStatesEqual: @escaping (_ lhs: DomainState, _ rhs: DomainState) -> Bool
    ) {
        self.viewStateReducer = viewStateReducer
        self.areStatesEqual = areStatesEqual
        self.runtime = FeatureRuntime(
            initialState: initialDomainState,
            interactor: interactor
        )

        var viewState = initialViewState()
        viewStateReducer.reduce(initialDomainState, into: &viewState)
        self._viewState = viewState

        runtime.setStepHandler { [weak self] step in
            guard let self else { return }
            let shouldReduceViewState =
                step.source == .emitted || !self.areStatesEqual(step.previousState, step.currentState)

            guard shouldReduceViewState else { return }
            self.viewStateReducer.reduce(step.currentState, into: &self.viewState)
        }
    }

    convenience init<I, R>(
        initialDomainState: DomainState,
        interactor: I,
        viewStateReducer: R,
        areStatesEqual: @escaping (_ lhs: DomainState, _ rhs: DomainState) -> Bool
    )
    where
        I: Interactor & Sendable,
        R: ViewStateReducer & Sendable,
        I.DomainState == DomainState, I.Action == Action,
        R.DomainState == DomainState, R.ViewState == ViewState
    {
        let initialViewState = viewStateReducer.initialViewState(for: initialDomainState)
        self.init(
            initialDomainState: initialDomainState,
            initialViewState: initialViewState,
            interactor: interactor.eraseToAnyInteractor(),
            viewStateReducer: viewStateReducer.eraseToAnyReducer(),
            areStatesEqual: areStatesEqual
        )
    }

    init(
        initialState: ViewState,
        interactor: AnyInteractor<ViewState, Action>,
        areStatesEqual: @escaping (_ lhs: DomainState, _ rhs: DomainState) -> Bool
    ) where DomainState == ViewState {
        self.viewStateReducer = BuildViewState<ViewState, ViewState> { domainState, viewState in
            viewState = domainState
        }.eraseToAnyReducer()
        self._viewState = initialState
        self.areStatesEqual = areStatesEqual
        self.runtime = FeatureRuntime(
            initialState: initialState,
            interactor: interactor
        )

        runtime.setStepHandler { [weak self] step in
            guard let self else { return }
            let shouldReduceViewState =
                step.source == .emitted || !self.areStatesEqual(step.previousState, step.currentState)

            guard shouldReduceViewState else { return }
            self.viewStateReducer.reduce(step.currentState, into: &self.viewState)
        }
    }

    public private(set) var viewState: ViewState {
        get {
            _$observationRegistrar.access(self, keyPath: \.viewState)
            return _viewState
        }
        set {
            if _viewState._$id == newValue._$id {
                _viewState = newValue
            } else {
                _$observationRegistrar.withMutation(of: self, keyPath: \.viewState) {
                    _viewState = newValue
                }
            }
        }
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<ViewState, Value>) -> Value {
        self.viewState[keyPath: keyPath]
    }

    /// Sends an action to the interactor and returns a task handle.
    ///
    /// - Parameter event: The action to send.
    /// - Returns: An ``EventTask`` representing the spawned effects.
    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask {
        runtime.send(event)
    }

    deinit {
        runtime.cancelAllEffects()
    }
}

extension ViewModel where DomainState: Equatable {
    convenience init(
        initialDomainState: DomainState,
        initialViewState: @autoclosure () -> ViewState,
        interactor: AnyInteractor<DomainState, Action>,
        viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    ) {
        self.init(
            initialDomainState: initialDomainState,
            initialViewState: initialViewState(),
            interactor: interactor,
            viewStateReducer: viewStateReducer,
            areStatesEqual: { lhs, rhs in lhs == rhs }
        )
    }

    convenience init<I, R>(
        initialDomainState: DomainState,
        interactor: I,
        viewStateReducer: R
    )
    where
        I: Interactor & Sendable,
        R: ViewStateReducer & Sendable,
        I.DomainState == DomainState, I.Action == Action,
        R.DomainState == DomainState, R.ViewState == ViewState
    {
        self.init(
            initialDomainState: initialDomainState,
            interactor: interactor,
            viewStateReducer: viewStateReducer,
            areStatesEqual: { lhs, rhs in lhs == rhs }
        )
    }

    convenience init(
        initialState: ViewState,
        interactor: AnyInteractor<ViewState, Action>
    ) where DomainState == ViewState {
        self.init(
            initialDomainState: initialState,
            initialViewState: initialState,
            interactor: interactor,
            viewStateReducer: BuildViewState<ViewState, ViewState> { domainState, viewState in
                viewState = domainState
            }.eraseToAnyReducer(),
            areStatesEqual: { lhs, rhs in lhs == rhs }
        )
    }
}
