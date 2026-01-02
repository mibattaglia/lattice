import Combine
import SwiftUI

/// A generic class that binds a SwiftUI view to your domain/business logic.
///
/// `ViewModel` is a coordinator that connects UI events to the interactor system
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
/// ## Initialization Patterns
///
/// ### Full Initialization (with ViewStateReducer)
///
/// Use this pattern when domain state differs from view state and requires transformation:
///
/// ```swift
/// let viewModel = ViewModel(
///     initialValue: CounterViewState(count: 0, displayText: ""),
///     CounterInteractor().eraseToAnyInteractor(),
///     CounterViewStateReducer().eraseToAnyViewStateReducer()
/// )
/// ```
///
/// ### Direct Initialization (DomainState == ViewState)
///
/// Use this pattern when the interactor's output can be used directly as view state:
///
/// ```swift
/// let viewModel = ViewModel(
///     CounterState(count: 0),
///     CounterInteractor().eraseToAnyInteractor()
/// )
/// ```
///
/// Or use the ``DirectViewModel`` typealias for clarity:
///
/// ```swift
/// let viewModel: DirectViewModel<CounterAction, CounterState> = ViewModel(
///     CounterState(count: 0),
///     CounterInteractor().eraseToAnyInteractor()
/// )
/// ```
///
/// ## Key Components
///
/// - `viewState`: A published property optimized for view rendering
/// - `sendViewEvent(_:)`: Method to dispatch user actions to the architecture
///
/// ## SwiftUI Integration
///
/// Use `@StateObject` or `@ObservedObject` to observe the view model:
///
/// ```swift
/// struct CounterView: View {
///     @StateObject var viewModel: ViewModel<CounterAction, CounterState, CounterViewState>
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
public final class ViewModel<Action, DomainState, ViewState>: ObservableObject
where Action: Sendable, DomainState: Sendable {
    @Published public private(set) var viewState: ViewState

    private var viewEventContinuation: AsyncStream<Action>.Continuation?
    private var subscriptionTask: Task<Void, Never>?

    public init(
        initialValue: @autoclosure () -> ViewState,
        _ interactor: AnyInteractor<DomainState, Action>,
        _ viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    ) {
        self.viewState = initialValue()

        let (stream, continuation) = AsyncStream.makeStream(of: Action.self)
        self.viewEventContinuation = continuation
        self.subscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await domainState in interactor.interact(stream) {
                guard !Task.isCancelled else {
                    break
                }
                viewStateReducer.reduce(domainState, into: &self.viewState)
            }
        }
    }

    public init(
        _ initialValue: @autoclosure () -> ViewState,
        _ interactor: AnyInteractor<ViewState, Action>
    ) where DomainState == ViewState {
        self.viewState = initialValue()

        let (stream, continuation) = AsyncStream.makeStream(of: Action.self)
        self.viewEventContinuation = continuation
        self.subscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            for await viewState in interactor.interact(stream) {
                self.viewState = viewState
            }
        }
    }

    public func sendViewEvent(_ event: Action) {
        viewEventContinuation?.yield(event)
    }

    deinit {
        viewEventContinuation?.finish()
        subscriptionTask?.cancel()
    }
}

public typealias DirectViewModel<Action: Sendable, State: Sendable> = ViewModel<Action, State, State>
