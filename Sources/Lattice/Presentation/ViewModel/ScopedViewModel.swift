import SwiftUI

#if canImport(CasePaths)
    import CasePaths
#endif

/// A stateless, fine-grained projection of a parent ``ViewModel`` onto a child slice of view
/// state and a child action space.
///
/// Create a scope with ``ViewModel/scope(state:action:)``. Reads register on the parent's
/// nested observation registrar, so a child view re-renders only when its own slice changes;
/// ``sendViewEvent(_:)`` embeds child actions into the parent action and runs them on the
/// parent's action loop.
///
/// ## Observe members, not the container
///
/// Read **members** through the scope (`model.title`, `model.badge.count`, or
/// ``binding(_:sending:)``) so observation tracks the live getter chain and the view re-renders
/// on in-place mutations. Reading the whole-slice ``viewState`` value registers only the
/// container's identity and will **not** re-render on an in-place leaf mutation — exactly the
/// same distinction as `viewModel.title` (fine-grained) versus `viewModel.viewState` (coarse).
/// Member access at any depth stays fine-grained because each hop invokes a live
/// `@ObservableState` getter; the rule is the chain of getters you actually read, not how deep
/// the slice is. (`@ObservableState` shares its observation registrar across value copies, so
/// reading members off a stored copy still tracks the live state — only reading the *whole*
/// container value is coarse.)
///
/// `ScopedViewModel` is a value type that owns no state, effects, or lifecycle, so it is cheap
/// to recreate on every render.
///
/// Create scopes inline in `body` and do not store them (e.g. in `@State` or any long-lived
/// property): a scope strongly retains its parent ``ViewModel``, so storing one beyond the
/// render that created it extends the parent's lifetime and delays the effect cancellation
/// that runs in the parent's `deinit`.
@dynamicMemberLookup
@MainActor
public struct ScopedViewModel<ChildState: ObservableState, ChildAction: Sendable> {
    private let _state: @MainActor () -> ChildState
    private let _send: @MainActor (ChildAction) -> EventTask

    init(
        state: @escaping @MainActor () -> ChildState,
        send: @escaping @MainActor (ChildAction) -> EventTask
    ) {
        self._state = state
        self._send = send
    }

    /// The current value of the whole child slice.
    ///
    /// This is the **coarse** read: it registers only the slice's identity (`_$id`), so like
    /// ``ViewModel/viewState`` it re-renders only on a wholesale slice replacement and **not**
    /// on an in-place leaf mutation. To observe leaf changes fine-grained, read members through
    /// the scope instead (`model.title`), which is the common case.
    public var viewState: ChildState { _state() }

    /// Accesses a member of the child slice with fine-grained observation.
    ///
    /// This is the **fine-grained** read: `model.title` (or deeper, `model.badge.count`) walks
    /// the live `@ObservableState` getter chain and re-renders the view on in-place mutations
    /// of that member. Prefer this over ``viewState`` in views.
    public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, Value>) -> Value {
        _state()[keyPath: keyPath]
    }

    /// Sends a child action, embedding it into the parent action and running it on the parent's
    /// action loop.
    ///
    /// To hand off to a child view that takes a `(ChildAction) -> Void` callback, wrap in a
    /// closure (the returned ``EventTask`` is discarded):
    ///
    /// ```swift
    /// ChildView(action: { scoped.sendViewEvent($0) })
    /// ```
    ///
    /// For a child declared with a type-erased `(Any) -> Void` callback, bridge at the call
    /// site, where the consumer who chose erasure owns the cast and its mismatch policy:
    ///
    /// ```swift
    /// ErasedChildView(action: { if let a = $0 as? ChildAction { scoped.sendViewEvent(a) } })
    /// ```
    ///
    /// - Parameter action: The child action to embed and dispatch.
    /// - Returns: The parent's ``EventTask`` for the dispatched action.
    @discardableResult
    public func sendViewEvent(_ action: ChildAction) -> EventTask {
        _send(action)
    }

    #if canImport(CasePaths)
        /// Returns a binding whose getter reads the given key path with fine-grained
        /// observation and whose setter sends the new value embedded as a child action.
        ///
        /// - Parameters:
        ///   - keyPath: A key path into the child slice to read.
        ///   - embed: A case key path that wraps the new value into a child action.
        /// - Returns: A two-way binding over the child slice.
        public func binding<Value>(
            _ keyPath: KeyPath<ChildState, Value>,
            sending embed: CaseKeyPath<ChildAction, Value>
        ) -> Binding<Value> {
            let state = self._state
            let send = self._send
            return Binding(
                get: { state()[keyPath: keyPath] },
                set: { newValue in _ = send(embed(newValue)) }
            )
        }
    #endif
}

#if canImport(CasePaths)
    extension ViewModel where Action: CasePathable {
        /// Projects this view model onto a child slice of view state and a child action space.
        ///
        /// The child action is embedded into this feature's action with `actionCasePath`. This
        /// is sugar over the closure-based ``scope(state:action:)`` overload.
        ///
        /// - Parameters:
        ///   - stateKeyPath: A key path to a nested `@ObservableState` slice of the view state.
        ///   - actionCasePath: A case key path that embeds the child action into this feature's
        ///     action.
        /// - Returns: A ``ScopedViewModel`` over the child slice and action.
        public func scope<ChildState: ObservableState, ChildAction: Sendable>(
            state stateKeyPath: KeyPath<ViewState, ChildState>,
            action actionCasePath: CaseKeyPath<Action, ChildAction>
        ) -> ScopedViewModel<ChildState, ChildAction> {
            // A CaseKeyPath is callable as (ChildAction) -> Action, so forward to the closure
            // overload below. The case-path form is just ergonomic sugar.
            scope(state: stateKeyPath, action: { actionCasePath($0) })
        }
    }

    extension ScopedViewModel {
        /// Projects this scope onto a grandchild slice and action space, composing through the
        /// parent.
        ///
        /// - Parameters:
        ///   - stateKeyPath: A key path from the child slice to a nested `@ObservableState`
        ///     grandchild slice.
        ///   - embed: A case key path that embeds the grandchild action into the child action.
        /// - Returns: A ``ScopedViewModel`` over the grandchild slice and action.
        public func scope<GrandState: ObservableState, GrandAction: Sendable>(
            state stateKeyPath: KeyPath<ChildState, GrandState>,
            action embed: CaseKeyPath<ChildAction, GrandAction>
        ) -> ScopedViewModel<GrandState, GrandAction> {
            let state = self._state
            let send = self._send
            return ScopedViewModel<GrandState, GrandAction>(
                state: { state()[keyPath: stateKeyPath] },
                send: { grandAction in send(embed(grandAction)) }
            )
        }
    }

    extension ViewModel where ViewState: CasePathable, Action: CasePathable {
        /// Projects this view model onto the payload of an enum case of view state, if that case
        /// is currently active.
        ///
        /// This is the primitive form; ``scope(state:action:fileID:line:)`` is trapping sugar over
        /// it for use inside a matched `switch` case. Reads are live: the returned scope
        /// re-extracts the payload from the current view state on every access, so in-place payload
        /// mutations are observed fine-grained. If the case deactivates while the scope is still
        /// held (at most one transitional render), reads serve the payload captured at creation.
        ///
        /// Sends are embedded into this feature's action with `embed` and run on this view model's
        /// action loop. A send can arrive after the case has deactivated; the interactor should
        /// drop actions that no longer apply to the current state.
        ///
        /// - Parameters:
        ///   - casePath: A case key path to an `@ObservableState` payload of the view state enum.
        ///   - embed: A case key path that embeds the child action into this feature's action.
        /// - Returns: A scope over the case's payload, or `nil` if the case is not active.
        public func scopeIfActive<Child: ObservableState, ChildAction: Sendable>(
            state casePath: CaseKeyPath<ViewState, Child>,
            action embed: CaseKeyPath<Action, ChildAction>
        ) -> ScopedViewModel<Child, ChildAction>? {
            guard let snapshot = self.viewState[case: casePath] else { return nil }
            return ScopedViewModel(
                state: { [self] in self.viewState[case: casePath] ?? snapshot },
                send: { [self] childAction in self.sendViewEvent(embed(childAction)) }
            )
        }

        /// Projects this view model onto the payload of the currently active enum case of view
        /// state, trapping if the case is not active.
        ///
        /// Call this only inside a `switch` case that just matched the same case:
        ///
        /// ```swift
        /// switch viewModel.viewState {
        /// case .loading:
        ///     LoadingView()
        /// case .success:
        ///     SuccessView(model: viewModel.scope(state: \.success, action: \.success))
        /// }
        /// ```
        ///
        /// Body evaluation is synchronous on the main actor, so within a matched case this cannot
        /// trap. Use ``scopeIfActive(state:action:)`` when the case may legitimately be inactive.
        public func scope<Child: ObservableState, ChildAction: Sendable>(
            state casePath: CaseKeyPath<ViewState, Child>,
            action embed: CaseKeyPath<Action, ChildAction>,
            fileID: StaticString = #fileID,
            line: UInt = #line
        ) -> ScopedViewModel<Child, ChildAction> {
            guard let scoped = scopeIfActive(state: casePath, action: embed) else {
                fatalError(
                    """
                    scope(state:action:) at \(fileID):\(line): scoped into case '\(casePath)' \
                    while it is not the active case of the view state. Call this only inside a \
                    switch case that matched the same case, or use scopeIfActive(state:action:).
                    """
                )
            }
            return scoped
        }
    }

    extension ScopedViewModel where ChildState: CasePathable {
        /// Projects this scope onto the payload of an enum case of the child slice, if active.
        /// See ``ViewModel/scopeIfActive(state:action:)``.
        public func scopeIfActive<CaseState: ObservableState, CaseAction: Sendable>(
            state casePath: CaseKeyPath<ChildState, CaseState>,
            action embed: CaseKeyPath<ChildAction, CaseAction>
        ) -> ScopedViewModel<CaseState, CaseAction>? {
            guard let snapshot = _state()[case: casePath] else { return nil }
            let state = self._state
            let send = self._send
            return ScopedViewModel<CaseState, CaseAction>(
                state: { state()[case: casePath] ?? snapshot },
                send: { caseAction in send(embed(caseAction)) }
            )
        }

        /// Projects this scope onto the payload of the currently active enum case of the child
        /// slice, trapping if the case is not active. See ``ViewModel/scope(state:action:fileID:line:)``.
        public func scope<CaseState: ObservableState, CaseAction: Sendable>(
            state casePath: CaseKeyPath<ChildState, CaseState>,
            action embed: CaseKeyPath<ChildAction, CaseAction>,
            fileID: StaticString = #fileID,
            line: UInt = #line
        ) -> ScopedViewModel<CaseState, CaseAction> {
            guard let scoped = scopeIfActive(state: casePath, action: embed) else {
                fatalError(
                    """
                    scope(state:action:) at \(fileID):\(line): scoped into case '\(casePath)' \
                    while it is not the active case of the child slice. Call this only inside a \
                    switch case that matched the same case, or use scopeIfActive(state:action:).
                    """
                )
            }
            return scoped
        }
    }
#endif

extension ViewModel {
    /// Projects this view model onto a child slice of view state and a child action space,
    /// mapping child actions into parent actions with a closure.
    ///
    /// This is the general form and has no `CasePathable` requirement; the case-path
    /// ``scope(state:action:)`` overload is sugar over it. Reach for it when the parent action
    /// is not `@CasePathable`, or when the mapping is not a plain case embedding.
    ///
    /// - Parameters:
    ///   - stateKeyPath: A key path to a nested `@ObservableState` slice of the view state.
    ///   - embed: A closure that maps a child action into this feature's action.
    /// - Returns: A ``ScopedViewModel`` over the child slice and action.
    public func scope<ChildState: ObservableState, ChildAction: Sendable>(
        state stateKeyPath: KeyPath<ViewState, ChildState>,
        action embed: @escaping @MainActor (ChildAction) -> Action
    ) -> ScopedViewModel<ChildState, ChildAction> {
        ScopedViewModel(
            state: { [self] in self[dynamicMember: stateKeyPath] },  // fine-grained (Spec A)
            send: { [self] childAction in self.sendViewEvent(embed(childAction)) }
        )
    }

    /// Projects this view model onto a read-only child slice, for child views that display
    /// state but send no actions.
    ///
    /// - Parameter stateKeyPath: A key path to a nested `@ObservableState` slice of the view
    ///   state.
    /// - Returns: A ``ScopedViewModel`` whose action type is `Never`.
    public func scope<ChildState: ObservableState>(
        state stateKeyPath: KeyPath<ViewState, ChildState>
    ) -> ScopedViewModel<ChildState, Never> {
        ScopedViewModel(
            state: { [self] in self[dynamicMember: stateKeyPath] },
            send: { (_: Never) in EventTask(rawValue: nil) }
        )
    }
}
