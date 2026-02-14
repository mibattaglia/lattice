import Observation
import SwiftUI

@MainActor
protocol _ViewModel {
    associatedtype ViewState: ObservableState

    var viewState: ViewState { get }
}

/// A convenience alias for expressing a view model using a single feature type.
///
/// ```swift
/// typealias CounterFeature = Feature<CounterAction, CounterState, CounterViewState>
/// @State var viewModel: ViewModelOf<CounterFeature>
/// ```
public typealias ViewModelOf<F: FeatureProtocol> = ViewModel<F>

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
/// ## Initialization
///
/// Use a ``Feature`` value to initialize a view model.
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
/// Use ``EventTask/finish()`` to await effect completion:
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
    private var domainState: DomainState
    private var effectTasks: [UUID: Task<Void, Never>] = [:]

    private let interactor: AnyInteractor<DomainState, Action>
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

    /// Internal initialization lane retained for framework tests during migration.
    internal init(
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

    /// Internal initialization lane retained for framework tests during migration.
    internal convenience init<I, R>(
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

    /// Internal initialization lane retained for framework tests during migration.
    internal init(
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
    internal convenience init(
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

    internal convenience init<I, R>(
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

    internal convenience init(
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
