import Combine
import SwiftUI

/// A type that binds a SwiftUI view to your domain/business logic.
///
/// In Uno, a ``ViewModel`` can be thought of as a coordinator that connects
/// streams of events from some UI component and feeds these events into a transformation system.
///
/// The ``ViewModel`` also acts as the main entry point in a feature's architecture stack. Feature state
/// is modeled as a single entry point, uni-directional system that consumes an event, transforms it and republishes
/// new state at the end of the chain. It is impossible for the ``ViewModel`` to reach back into another component
/// and change state while an action is running.
///
/// ### Declaring a ViewModel
/// ```swift
/// @ViewModel<CounterViewState, CounterEvent>
/// final class CounterViewModel {
///     init(
///         interactor: AnyInteractor<CounterDomainState, CounterEvent>,
///         viewStateReducer: AnyViewStateReducer<CounterDomainState, CounterViewState>
///     ) {
///         // You must provide an initial value for `viewState`
///         self.viewState = .loading
///         // The ``subscribe(_:)`` macro generates an observation pipeline
///         // that binds your feature's state to a UI component.
///         #subscribe { builder in
///             builder
///                 .interactor(interactor)
///                 .viewStateReducer(viewStateReducer)
///         }
///     }
///
/// }
/// ```
///
/// ``ViewModel`` exposes
/// * `viewState` – a data structure distilled down for presentation purposes.
/// * `sendViewEvent(_:)` – a method to deliver user events back to the architecture.
@MainActor
public protocol ViewModel: ObservableObject, Sendable {
    associatedtype ViewEventType
    associatedtype ViewStateType

    var viewState: ViewStateType { get }

    func sendViewEvent(_ event: ViewEventType)
}

/// A type-erased wrapper around any ``ViewModel``.
@MainActor
public final class AnyViewModel<ViewEvent, ViewState>: ViewModel {
    public var viewState: ViewState { viewStateGetter() }

    private let viewStateGetter: @MainActor () -> ViewState
    private let viewEventSender: @MainActor (ViewEvent) -> Void
    private var cancellable: AnyCancellable?

    /// Creates a type-erased wrapper around `base`.
    ///
    /// - Note: The wrapper relays `objectWillChange` so that SwiftUI updates continue to work.
    public init<VM: ViewModel>(_ base: VM)
    where VM.ViewEventType == ViewEvent, VM.ViewStateType == ViewState {
        self.viewEventSender = { [weak base] event in base?.sendViewEvent(event) }
        self.viewStateGetter = { [weak base] in
            guard let base else {
                fatalError("Underlying ViewModel deallocated")
            }
            return base.viewState
        }

        self.cancellable = base.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    /// Forwards the view event to the underlying view model.
    public func sendViewEvent(_ event: ViewEvent) {
        viewEventSender(event)
    }
}

extension ViewModel {
    /// Erases `self` to ``AnyViewModel``.
    public func erased() -> AnyViewModel<ViewEventType, ViewStateType> {
        AnyViewModel(self)
    }
}
