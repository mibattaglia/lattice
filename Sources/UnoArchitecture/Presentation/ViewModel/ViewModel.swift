import Combine
import SwiftUI

/// A type that binds a SwiftUI view to your domain/business logic.
///
/// A `ViewModel` is a coordinator that connects UI events to the interactor system
/// and publishes view state changes back to SwiftUI. It serves as the main entry point
/// for a feature's architecture.
///
/// ## Overview
///
/// The data flow is unidirectional:
///
/// 1. View calls `sendViewEvent(_:)` with user actions
/// 2. Events are forwarded to the ``Interactor``
/// 3. The interactor emits domain state
/// 4. The ``ViewStateReducer`` transforms domain state to view state
/// 5. View observes `viewState` changes and re-renders
///
/// ## Declaring a ViewModel
///
/// Use the `@ViewModel` macro for a concise declaration:
///
/// ```swift
/// @MainActor
/// @ViewModel<CounterViewState, CounterEvent>
/// final class CounterViewModel {
///     init(
///         interactor: AnyInteractor<CounterDomainState, CounterEvent>,
///         viewStateReducer: AnyViewStateReducer<CounterDomainState, CounterViewState>
///     ) {
///         self.viewState = .initial
///         #subscribe { builder in
///             builder
///                 .interactor(interactor)
///                 .viewStateReducer(viewStateReducer)
///         }
///     }
/// }
/// ```
///
/// ## Key Components
///
/// - `viewState`: A data structure optimized for view rendering
/// - `sendViewEvent(_:)`: Method to send user events to the architecture
///
/// ## SwiftUI Integration
///
/// Use `@StateObject` or `@ObservedObject` to observe the view model:
///
/// ```swift
/// struct CounterView: View {
///     @StateObject var viewModel: CounterViewModel
///
///     var body: some View {
///         Text("Count: \(viewModel.viewState.count)")
///         Button("Increment") {
///             viewModel.sendViewEvent(.increment)
///         }
///     }
/// }
/// ```
@MainActor
public protocol ViewModel: ObservableObject, Sendable {
    /// The type of events sent from the view.
    associatedtype ViewEventType
    /// The type of state observed by the view.
    associatedtype ViewStateType

    /// The current view state, observed by SwiftUI for rendering.
    var viewState: ViewStateType { get }

    /// Sends a view event to the architecture for processing.
    ///
    /// - Parameter event: The event triggered by user interaction.
    func sendViewEvent(_ event: ViewEventType)
}

/// A type-erased wrapper around any ``ViewModel``.
///
/// Use `AnyViewModel` when you need to store view models with different concrete
/// types but the same `ViewEvent` and `ViewState` types.
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
