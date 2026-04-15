import DequeModule
import Observation
import OrderedCollections
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
/// 5. Any async effects from the emission are spawned as tasks inside the originating root send scope
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
/// Use ``EventTask/finish()`` to await transitive effect completion when needed:
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

    private var domainState: DomainState
    private var bufferedActions: Deque<BufferedAction<Action>> = []
    private var rootScopes: OrderedDictionary<SendScopeID, RootScopeState> = [:]
    private var effectTasks: OrderedDictionary<EffectID, Task<Void, Never>> = [:]
    private var isSending = false

    private var _viewState: ViewState

    private let interactor: AnyInteractor<DomainState, Action>
    private let viewStateReducer: AnyViewStateReducer<DomainState, ViewState>
    private let areStatesEqual: (_ lhs: DomainState, _ rhs: DomainState) -> Bool
    private nonisolated let taskRegistry = EffectTaskRegistry()

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
        self.domainState = initialDomainState
        self.interactor = interactor
        self.viewStateReducer = viewStateReducer
        self.areStatesEqual = areStatesEqual

        var viewState = initialViewState()
        viewStateReducer.reduce(initialDomainState, into: &viewState)
        self._viewState = viewState
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
        self.domainState = initialState
        self.interactor = interactor
        self.viewStateReducer = BuildViewState<ViewState, ViewState> { domainState, viewState in
            viewState = domainState
        }.eraseToAnyReducer()
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

    /// Sends an action to the interactor and returns a handle for the root send scope.
    ///
    /// - Parameter event: The action to send.
    /// - Returns: An ``EventTask`` whose `finish()` waits for recursively emitted child work
    ///   started from this send, and whose `cancel()` cancels the currently tracked work in
    ///   that scope.
    @discardableResult
    public func sendViewEvent(_ event: Action) -> EventTask {
        let rootScopeID = SendScopeID()
        enqueue(event, source: .sent, rootScopeID: rootScopeID)
        drainBufferedActionsIfNeeded()
        return makeEventTask(for: rootScopeID)
    }

    deinit {
        taskRegistry.cancelAll()
    }

    private func enqueue(
        _ action: Action,
        source: ActionSource,
        rootScopeID: SendScopeID
    ) {
        bufferedActions.append(
            .init(
                action: action,
                source: source,
                rootScopeID: rootScopeID
            )
        )

        var rootScope = rootScopes[rootScopeID] ?? .init()
        rootScope.bufferedActionCount += 1
        rootScopes[rootScopeID] = rootScope
    }

    private func drainBufferedActionsIfNeeded() {
        guard !isSending else { return }

        isSending = true
        defer { isSending = false }

        while let bufferedAction = bufferedActions.popFirst() {
            guard var rootScope = rootScopes[bufferedAction.rootScopeID] else {
                continue
            }

            rootScope.bufferedActionCount -= 1
            rootScopes[bufferedAction.rootScopeID] = rootScope

            var workingState = domainState
            let transition = ActionTransition.apply(
                bufferedAction.action,
                source: bufferedAction.source,
                rootScopeID: bufferedAction.rootScopeID,
                to: &workingState,
                using: interactor
            )

            commitProductionTransition(transition)
            spawnEffects(
                from: transition.emission,
                rootScopeID: bufferedAction.rootScopeID
            )
            pruneRootScopeIfQuiescent(bufferedAction.rootScopeID)
        }
    }

    private func commitProductionTransition(
        _ transition: ActionTransition<DomainState, Action>
    ) {
        domainState = transition.currentState

        let shouldReduceViewState =
            transition.source == .emitted
            || !areStatesEqual(transition.previousState, transition.currentState)

        guard shouldReduceViewState else { return }
        viewStateReducer.reduce(transition.currentState, into: &viewState)
    }

    private func spawnEffects(
        from emission: Emission<Action>,
        rootScopeID: SendScopeID
    ) {
        let spawnedTasks = EmissionExecution.spawnTasks(
            from: emission,
            rootScopeID: rootScopeID,
            makeEffectID: { EffectID() },
            effectDidStart: { [weak self] effectID in
                self?.enrollEffect(effectID, rootScopeID: rootScopeID)
            },
            effectDidComplete: { [weak self] effectID in
                self?.completeEffect(effectID, rootScopeID: rootScopeID)
            },
            effectDidCancel: { [weak self] effectID in
                self?.cancelEffect(effectID, rootScopeID: rootScopeID)
            },
            enqueueEmittedAction: { [weak self] action, rootScopeID in
                guard let self else { return }
                self.enqueue(action, source: .emitted, rootScopeID: rootScopeID)
                self.drainBufferedActionsIfNeeded()
            }
        )

        for (effectID, task) in spawnedTasks {
            effectTasks[effectID] = task
        }
        taskRegistry.insert(spawnedTasks)
    }

    private func enrollEffect(
        _ effectID: EffectID,
        rootScopeID: SendScopeID
    ) {
        var rootScope = rootScopes[rootScopeID] ?? .init()
        rootScope.inFlightEffectIDs.insert(effectID)
        rootScopes[rootScopeID] = rootScope
    }

    private func completeEffect(
        _ effectID: EffectID,
        rootScopeID: SendScopeID
    ) {
        effectTasks[effectID] = nil
        taskRegistry.remove([effectID])

        guard var rootScope = rootScopes[rootScopeID] else { return }
        rootScope.inFlightEffectIDs.remove(effectID)
        rootScopes[rootScopeID] = rootScope

        pruneRootScopeIfQuiescent(rootScopeID)
    }

    private func cancelEffect(
        _ effectID: EffectID,
        rootScopeID: SendScopeID
    ) {
        completeEffect(effectID, rootScopeID: rootScopeID)
    }

    private func makeEventTask(for rootScopeID: SendScopeID) -> EventTask {
        guard rootScopes[rootScopeID] != nil else {
            return EventTask(rawValue: nil)
        }

        return EventTask(
            rawValue: RootScopeTasks.makeTask(
                rootScopeID: rootScopeID,
                isQuiescent: { [weak self] rootScopeID in
                    self?.isRootScopeQuiescent(rootScopeID) ?? true
                },
                cancelScope: { [weak self] rootScopeID in
                    self?.cancelRootScope(rootScopeID)
                }
            )
        )
    }

    private func isRootScopeQuiescent(_ rootScopeID: SendScopeID) -> Bool {
        rootScopes[rootScopeID]?.isQuiescent ?? true
    }

    private func cancelRootScope(_ rootScopeID: SendScopeID) {
        guard let rootScope = rootScopes[rootScopeID] else { return }

        for effectID in rootScope.inFlightEffectIDs {
            effectTasks[effectID]?.cancel()
        }
    }

    private func pruneRootScopeIfQuiescent(_ rootScopeID: SendScopeID) {
        guard rootScopes[rootScopeID]?.isQuiescent == true else { return }
        rootScopes[rootScopeID] = nil
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
