import DequeModule
import Observation
import OrderedCollections
import SwiftUI

#if canImport(CasePaths)
    import CasePaths
#endif

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
public final class ViewModel<F: FeatureProtocol>: Observable {
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
    private nonisolated let cancellationRegistry = EffectCancellationRegistry()

    private let rootSignal = _FeatureStateSignal()
    private let featureStateRegistry = _FeatureStateRegistry()
    private var featureStateContext: _FeatureStateContext<DomainState>?


    /// Creates a ViewModel for a concrete feature.
    ///
    /// - Parameters:
    ///   - initialDomainState: The initial domain state value.
    ///   - feature: The feature bundle containing interactor/reducer wiring.
    public convenience init(
        initialDomainState: DomainState,
        feature: F
    ) where ViewState: ObservableState {
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

    public init(initialDomainState: DomainState, feature: F)
    where DomainState: FeatureStateProtocol, ViewState == _FeatureStatePresentation {
        domainState = initialDomainState
        interactor = feature.interactor
        viewStateReducer = feature.viewStateReducer
        areStatesEqual = feature.areStatesEqual
        _viewState = _FeatureStatePresentation()
        // The empty T1 marker never runs a reducer or a production comparator.
        featureStateContext = _FeatureStateContext(
            registry: featureStateRegistry, signal: rootSignal,
            value: { [unowned self] in domainState }, isLive: { true }
        )
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
        cancellationRegistry.cancelAll()
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
        let oldIdentity = (domainState as? any FeatureStateProtocol)?._featureStateIdentity
        domainState = transition.currentState

        if featureStateContext != nil {
            // All live paths/result slots receive final committed values before
            // any host replacement signal. Native field callbacks already ran
            // against the independent working copy, often reading old state.
            let signals = featureStateRegistry.stage()
            for signal in signals { signal.notify() }
            if oldIdentity != (domainState as? any FeatureStateProtocol)?._featureStateIdentity {
                rootSignal.notify()
            }
            return
        }

        let shouldReduceViewState =
            transition.source == .emitted
            || !areStatesEqual(transition.previousState, transition.currentState)

        guard shouldReduceViewState else { return }

        // The reducer must never run while a formal access on `_viewState` is open: an
        // `@ObservableState` field mutation fires `willSet` to synchronous observers (e.g. SwiftUI
        // body re-evaluation) mid-reduce, and if one re-reads `viewState` the getter opens a
        // conflicting read against an open write — a Swift exclusivity trap
        // (see `ViewModelReentrancyTests`). Reducing into a local working copy avoids the
        // trap: `@ObservableState` registrars are reference types, so the copy shares the same
        // registrar tree and per-field notifications/identity are unaffected. The coarse
        // `\.viewState` fire stays gated on a root `_$id` change and moves after the single commit
        // store, preserving today's ordering.
        var workingViewState = _viewState
        viewStateReducer.reduce(transition.currentState, into: &workingViewState)
        let oldID = (_viewState as? any ObservableState)?._$id
        _viewState = workingViewState
        if (_viewState as? any ObservableState)?._$id != oldID {
            rootSignal.notify()
        }
    }

    private func spawnEffects(
        from emission: Emission<Action>,
        rootScopeID: SendScopeID
    ) {
        let spawnedTasks = EmissionExecution.spawnTasks(
            from: emission,
            rootScopeID: rootScopeID,
            cancellationRegistry: cancellationRegistry,
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

extension ViewModel: _ViewModel where ViewState: ObservableState {}

extension ViewModel where ViewState: ObservableState {
    public private(set) var viewState: ViewState {
        get {
            rootSignal.access()
            return _viewState
        }
        set {
            if _viewState._$id == newValue._$id {
                _viewState = newValue
            } else {
                _viewState = newValue
                rootSignal.notify()
            }
        }
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<ViewState, Value>) -> Value {
        self.viewState[keyPath: keyPath]
    }

}

extension ViewModel where DomainState: FeatureStateProtocol, ViewState == _FeatureStatePresentation {

    public subscript<Value>(
        dynamicMember member: KeyPath<DomainState._ViewMembers, FeatureStateValueMember<DomainState, Value>>
    ) -> Value {
        featureStateContext!.read()[keyPath: DomainState._viewMembers[keyPath: member].keyPath]
    }

    public subscript<Row: FeatureStateProtocol & Identifiable>(
        dynamicMember member: KeyPath<DomainState._ViewMembers, FeatureStateRowsMember<DomainState, Row>>
    ) -> ScopedViewModelCollection<Row> {
        let descriptor = DomainState._viewMembers[keyPath: member]
        let context = featureStateContext!
        return context.rows(key: member, values: descriptor.read(context.read()), read: descriptor.read, owner: self)
    }

    public func scope<Child: FeatureStateProtocol, ChildAction: Sendable>(
        state member: KeyPath<DomainState._ViewMembers, FeatureStateChildMember<DomainState, Child>>,
        action embed: @escaping @MainActor (ChildAction) -> Action
    ) -> ScopedViewModel<Child, ChildAction> {
        let descriptor = DomainState._viewMembers[keyPath: member]
        let parent = featureStateContext!
        let seed = parent.read()[keyPath: descriptor.keyPath]
        let context = parent.child(key: member, seed: seed, read: descriptor.read)
        return ScopedViewModel(context: context, owner: self, send: { [self] in sendViewEvent(embed($0)) })
    }

    public func scope<Child: FeatureStateProtocol>(
        state member: KeyPath<DomainState._ViewMembers, FeatureStateChildMember<DomainState, Child>>
    ) -> ScopedViewModel<Child, Never> {
        scope(state: member, action: _uninhabitedFeatureAction)
    }

    public func scopeIfPresent<Child: FeatureStateProtocol, ChildAction: Sendable>(
        state member: KeyPath<DomainState._ViewMembers, FeatureStateOptionalMember<DomainState, Child>>,
        action embed: @escaping @MainActor (ChildAction) -> Action
    ) -> ScopedViewModel<Child, ChildAction>? {
        let descriptor = DomainState._viewMembers[keyPath: member]
        let parent = featureStateContext!
        guard let seed = parent.read()[keyPath: descriptor.keyPath] else { return nil }
        let context = parent.child(key: member, seed: seed, read: descriptor.read)
        return ScopedViewModel(context: context, owner: self, send: { [self] in sendViewEvent(embed($0)) })
    }

    public func scopeIfPresent<Child: FeatureStateProtocol>(
        state member: KeyPath<DomainState._ViewMembers, FeatureStateOptionalMember<DomainState, Child>>
    ) -> ScopedViewModel<Child, Never>? {
        scopeIfPresent(state: member, action: _uninhabitedFeatureAction)
    }

    public func binding<Value>(
        _ member: KeyPath<DomainState._ViewMembers, FeatureStateValueMember<DomainState, Value>>,
        sending embed: @escaping @MainActor (Value) -> Action
    ) -> Binding<Value> {
        Binding(get: { self[dynamicMember: member] }, set: { self.sendViewEvent(embed($0)) })
    }

    var featureStateRegistrationCount: Int { featureStateRegistry.count }
}

#if canImport(CasePaths)
    extension ViewModel where DomainState: FeatureStateProtocol, Action: CasePathable, ViewState == _FeatureStatePresentation {
        public func scope<Child: FeatureStateProtocol, ChildEvent: Sendable>(
            state member: KeyPath<DomainState._ViewMembers, FeatureStateChildMember<DomainState, Child>>,
            action embed: CaseKeyPath<Action, ChildEvent>
        ) -> ScopedViewModel<Child, ChildEvent> {
            scope(state: member, action: { embed($0) })
        }

        public func scopeIfPresent<Child: FeatureStateProtocol, ChildEvent: Sendable>(
            state member: KeyPath<DomainState._ViewMembers, FeatureStateOptionalMember<DomainState, Child>>,
            action embed: CaseKeyPath<Action, ChildEvent>
        ) -> ScopedViewModel<Child, ChildEvent>? {
            scopeIfPresent(state: member, action: { embed($0) })
        }

        public func binding<Value>(
            _ member: KeyPath<DomainState._ViewMembers, FeatureStateValueMember<DomainState, Value>>,
            sending embed: CaseKeyPath<Action, Value>
        ) -> Binding<Value> {
            binding(member, sending: { embed($0) })
        }
    }
#endif
