import Observation
import SwiftUI

@MainActor
protocol _ViewModel {
    associatedtype ViewState: ObservableState

    var viewState: ViewState { get }
}

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
/// 2. The ``Interactor`` processes the action synchronously and returns an ``Emission``
/// 3. State mutations are applied immediately
/// 4. The ``ViewStateReducer`` transforms domain state to view state
/// 5. Any async effects from the emission are spawned as tasks
/// 6. View observes `viewState` changes and re-renders
///
/// ## Initialization Patterns
///
/// ### Full Initialization (with ViewStateReducer)
///
/// Use this pattern when domain state differs from view state and requires transformation:
///
/// ```swift
/// let viewModel = ViewModel(
///     initialDomainState: CounterDomainState(count: 0),
///     interactor: CounterInteractor().eraseToAnyInteractor(),
///     viewStateReducer: CounterViewStateReducer().eraseToAnyReducer()
/// )
/// ```
///
/// ### Direct Initialization (DomainState == ViewState)
///
/// Use this pattern when the interactor's output can be used directly as view state:
///
/// ```swift
/// let viewModel = ViewModel(
///     initialState: CounterState(count: 0),
///     interactor: CounterInteractor().eraseToAnyInteractor()
/// )
/// ```
///
/// Or use the ``DirectViewModel`` typealias for clarity:
///
/// ```swift
/// let viewModel: DirectViewModel<CounterAction, CounterState> = ViewModel(
///     initialState: CounterState(count: 0),
///     interactor: CounterInteractor().eraseToAnyInteractor()
/// )
/// ```
///
/// ## Key Components
///
/// - `viewState`: A published property optimized for view rendering
/// - `sendViewEvent(_:)`: Method to dispatch user actions, returns ``EventTask``
///
/// ## SwiftUI Integration
///
/// Use `@State` to hold the view model:
///
/// ```swift
/// struct CounterView: View {
///     @State var viewModel = ViewModel(
///         initialState: CounterState(count: 0),
///         interactor: CounterInteractor().eraseToAnyInteractor()
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
/// Use ``EventTask/finish()`` to await effect completion:
///
/// ```swift
/// .refreshable {
///     await viewModel.sendViewEvent(.refresh).finish()
/// }
/// ```
@dynamicMemberLookup
@MainActor
public final class ViewModel<Action, DomainState, ViewState>: Observable, _ViewModel
where Action: Sendable, DomainState: Sendable, ViewState: ObservableState {
    private var _viewState: ViewState
    private var domainState: DomainState
    private var effectTasks: [UUID: Task<Void, Never>] = [:]

    private let interactor: AnyInteractor<DomainState, Action>
    private let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    private let areStatesEqual: (_ lhs: DomainState, _ rhs: DomainState) -> Bool

    private let _$observationRegistrar = ObservationRegistrar()

    /// Creates a ViewModel with separate domain and view state.
    ///
    /// The view state is automatically inflated by running the reducer with the initial domain state.
    ///
    /// - Parameters:
    ///   - initialDomainState: The initial domain state value.
    ///   - interactor: The interactor that processes actions.
    ///   - viewStateReducer: The reducer that transforms domain state to view state.
    ///   - initialViewState: A closure that provides the initial view state structure.
    public init(
        initialDomainState: DomainState,
        initialViewState: @autoclosure () -> ViewState,
        interactor: AnyInteractor<DomainState, Action>,
        viewStateReducer: AnyViewStateReducer<DomainState, ViewState>,
        areStatesEqual: @escaping (_ lhs: DomainState, _ rhs: DomainState) -> Bool
    ) {
        self.interactor = interactor
        self.viewStateReducer = viewStateReducer
        self.domainState = initialDomainState
        self.areStatesEqual = areStatesEqual

        var viewState = initialViewState()
        viewStateReducer.reduce(initialDomainState, into: &viewState)
        self._viewState = viewState
    }

    /// Creates a ViewModel where domain state is used directly as view state.
    ///
    /// - Parameters:
    ///   - initialState: The initial state value (serves as both domain and view state).
    ///   - interactor: The interactor that processes actions.
    public init(
        initialState: ViewState,
        interactor: AnyInteractor<ViewState, Action>,
        areStatesEqual: @escaping (_ lhs: DomainState, _ rhs: DomainState) -> Bool
    ) where DomainState == ViewState {
        self.interactor = interactor
        self.viewStateReducer = BuildViewState<ViewState, ViewState> { domainState, viewState in
            viewState = domainState
        }.eraseToAnyReducer()
        self.domainState = initialState
        self._viewState = initialState
        self.areStatesEqual = areStatesEqual
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
        let originalDomainState = domainState
        let emission = interactor.interact(state: &domainState, action: event)
        if !areStatesEqual(originalDomainState, domainState) {
            viewStateReducer.reduce(domainState, into: &viewState)
        }

        let spawnedTasks = spawnTasks(from: emission)
        let spawnedUUIDs = Set(spawnedTasks.keys)
        effectTasks.merge(spawnedTasks) { _, new in new }

        guard !spawnedTasks.isEmpty else {
            return EventTask(rawValue: nil)
        }

        let taskList = Array(spawnedTasks.values)
        let compositeTask = Task { [weak self] in
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    for task in taskList {
                        group.addTask { await task.value }
                    }
                }
            } onCancel: {
                for task in taskList {
                    task.cancel()
                }
            }
            for uuid in spawnedUUIDs {
                self?.effectTasks[uuid] = nil
            }
        }

        return EventTask(rawValue: compositeTask)
    }

    private func spawnTasks(from emission: Emission<Action>) -> [UUID: Task<Void, Never>] {
        switch emission.kind {
        case .none:
            return [:]

        case .action(let action):
            let innerEmission = interactor.interact(state: &domainState, action: action)
            viewStateReducer.reduce(domainState, into: &viewState)
            return spawnTasks(from: innerEmission)

        case .perform(let work):
            let uuid = UUID()
            let task = Task { [weak self] in
                guard let action = await work() else { return }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    let emission = self.interactor.interact(state: &self.domainState, action: action)
                    self.viewStateReducer.reduce(self.domainState, into: &self.viewState)
                    let newTasks = self.spawnTasks(from: emission)
                    self.effectTasks.merge(newTasks) { _, new in new }
                }
            }
            return [uuid: task]

        case .observe(let stream):
            let uuid = UUID()
            let task = Task { [weak self] in
                for await action in await stream() {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        guard let self else { return }
                        let emission = self.interactor.interact(state: &self.domainState, action: action)
                        self.viewStateReducer.reduce(self.domainState, into: &self.viewState)
                        let newTasks = self.spawnTasks(from: emission)
                        self.effectTasks.merge(newTasks) { _, new in new }
                    }
                }
            }
            return [uuid: task]

        case .merge(let emissions):
            return emissions.reduce(into: [:]) { result, emission in
                result.merge(spawnTasks(from: emission)) { _, new in new }
            }
        }
    }

    deinit {
        for task in effectTasks.values {
            task.cancel()
        }
    }
}

extension ViewModel where DomainState: Equatable {
    public convenience init(
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

    public convenience init(
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

/// A convenience typealias for ViewModels where domain state equals view state.
///
/// Usage:
/// ```swift
/// let viewModel: DirectViewModel<CounterAction, CounterState> = ViewModel(
///     CounterState(count: 0),
///     CounterInteractor().eraseToAnyInteractor()
/// )
/// ```
public typealias DirectViewModel<Action: Sendable, State: Sendable & ObservableState> = ViewModel<Action, State, State>
