import DequeModule
import Observation
import OrderedCollections
import SwiftUI

/// A generic class that binds a SwiftUI view to a feature's state and interactor.
///
/// `ViewModel` connects a ``Feature`` to SwiftUI. Views send user events through
/// ``sendViewEvent(_:)`` and read the state's view-facing projection, `State.ViewState`.
///
/// ## Overview
///
/// The data flow is unidirectional:
///
/// 1. View calls `sendViewEvent(_:)` with user actions
/// 2. The ``Interactor`` processes the action synchronously and returns an ``Emission``
/// 3. State mutations are applied immediately
/// 4. Any async effects from the emission are spawned as tasks inside the originating root send scope
/// 5. Views re-render from the members they read
///
/// ## Initialization
///
/// Create a view model from the initial state and a `Feature`:
///
/// ```swift
/// let viewModel = ViewModel(
///     initialState: CounterState(),
///     feature: Feature(interactor: CounterInteractor())
/// )
/// ```
///
/// ## Reading State
///
/// Views read through `State.ViewState`, the projection `@FeatureState` generates: `@Domain`
/// members are absent from it, and every member read stays observation-tracked.
///
/// - Member reads (`viewModel.title`, `viewModel.badge.count`) are fine-grained: a view
///   re-renders only when a member it read changes.
/// - ``viewState`` is the coarse read: the value re-renders on wholesale replacement or an enum
///   case change, while members read off it stay fine-grained.
///
/// ## SwiftUI Integration
///
/// Use `@State` to hold the view model:
///
/// ```swift
/// struct CounterView: View {
///     @State var viewModel = ViewModel(
///         initialState: CounterState(),
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
    public typealias State = F.State

    private var _state: State
    private var bufferedActions: Deque<BufferedAction<Action>> = []
    private var rootScopes: OrderedDictionary<SendScopeID, RootScopeState> = [:]
    private var effectTasks: OrderedDictionary<EffectID, Task<Void, Never>> = [:]
    private var isSending = false

    private let interactor: AnyInteractor<State, Action>
    private let areStatesEqual: ((_ lhs: State, _ rhs: State) -> Bool)?
    private nonisolated let taskRegistry = EffectTaskRegistry()
    private nonisolated let cancellationRegistry = EffectCancellationRegistry()

    private let _$observationRegistrar = ObservationRegistrar()

    /// Creates a view model for a concrete feature.
    ///
    /// - Parameters:
    ///   - initialState: The initial state value.
    ///   - feature: The feature bundle containing the interactor and the state equality.
    public init(initialState: State, feature: F) {
        self._state = initialState
        self.interactor = feature.interactor
        self.areStatesEqual = feature.areStatesEqual
    }

    /// Whole projection. The value itself is coarse: re-renders on wholesale replacement or enum
    /// case change. Members read off it stay fine-grained (the copy shares every registrar), so
    /// `switch viewModel.viewState { case .loaded(let l): Text(l.title) }` re-renders on case
    /// changes and on `title` changes only.
    public var viewState: State.ViewState { State.ViewState(state) }

    /// Member read with fine-grained observation; also registers the root, so struct states never
    /// need `viewState` for observation.
    public subscript<V>(dynamicMember keyPath: KeyPath<State.ViewState, V>) -> V {
        State.ViewState(state)[keyPath: keyPath]
    }

    /// Raw state. Internal: `TestViewModel`, `ScopedViewModel` and bindings live in this module.
    var state: State {
        _$observationRegistrar.access(self, keyPath: \.state)
        return _state
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

            var workingState = _state
            let transition = ActionTransition.apply(
                bufferedAction.action,
                source: bufferedAction.source,
                rootScopeID: bufferedAction.rootScopeID,
                to: &workingState,
                using: interactor
            )

            commit(transition)
            spawnEffects(
                from: transition.emission,
                rootScopeID: bufferedAction.rootScopeID
            )
            pruneRootScopeIfQuiescent(bufferedAction.rootScopeID)
        }
    }

    /// Stores the state an action produced.
    ///
    /// The interactor mutated a working copy whose registrars are shared with `_state`, so
    /// per-member notifications already fired during `interact(state:action:)`, and an observer
    /// that re-read this view model synchronously saw the previous committed value. Only a
    /// wholesale replacement (a new root `_$id`) fires the coarse `\.state` key path.
    private func commit(_ transition: ActionTransition<State, Action>) {
        let newState = transition.currentState
        let isReplacement = newState._$id != _state._$id
        if isReplacement, let areStatesEqual, areStatesEqual(_state, newState) {
            // Content-equal wholesale replacement: keep the current value so its registrar tree —
            // and every observer registered on it — survives. Nothing changed for the view.
            return
        }
        _state = newState
        if isReplacement {
            _$observationRegistrar.withMutation(of: self, keyPath: \.state) {}
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
