import IdentifiedCollections
import SwiftUI

#if canImport(CasePaths)
    import CasePaths
#endif

/// A stateless, fine-grained projection of a parent ``ViewModel`` onto a child feature state
/// and a child action space.
///
/// Create a scope with ``ViewModel/scope(state:action:)-swift.method``. The scope exposes the
/// **child's projection** — the same read surface the parent's dynamic member lookup returns
/// for a nested `@FeatureState` member — so access registration and per-member invalidation
/// work identically through a scope and through the root. ``sendViewEvent(_:)`` embeds child
/// actions into the parent action and dispatches them through the parent.
///
/// `ScopedViewModel` is a value type that owns no state, effects, or lifecycle, so it is cheap
/// to recreate on every render. Effect scoping — child task buckets, cancellation on case
/// exit, dropped `modify` after dismount — is entirely the core's job via `When` nodes and
/// `GraphPath` prefixes; the scope stays a stateless lens.
///
/// Create scopes inline in `body` and do not store them (e.g. in `@State` or any long-lived
/// property): a scope strongly retains its parent ``ViewModel``, so storing one beyond the
/// render that created it extends the parent's lifetime and delays the effect cancellation
/// that runs when the parent's core is torn down.
@dynamicMemberLookup
@MainActor
public struct ScopedViewModel<Child: FeatureStateProtocol, ChildAction> {
    let _projection: @MainActor () -> FeatureProjection<Child>
    let _send: @MainActor (ChildAction) -> EventTask

    init(
        projection: @escaping @MainActor () -> FeatureProjection<Child>,
        send: @escaping @MainActor (ChildAction) -> EventTask
    ) {
        self._projection = projection
        self._send = send
    }

    // The dynamic-member overload set mirrors ``FeatureProjection``'s
    // (leaf / child / optional child / collection), delegating to the child projection.

    @_disfavoredOverload
    public subscript<Value: Equatable>(
        dynamicMember member: KeyPath<Child._ViewMembers, Value>
    ) -> Value {
        _projection()[dynamicMember: member]
    }

    public subscript<Grand: FeatureStateProtocol>(
        dynamicMember member: KeyPath<Child._ViewMembers, Grand>
    ) -> FeatureProjection<Grand> {
        _projection()[dynamicMember: member]
    }

    public subscript<Grand: FeatureStateProtocol>(
        dynamicMember member: KeyPath<Child._ViewMembers, Grand?>
    ) -> FeatureProjection<Grand>? {
        _projection()[dynamicMember: member]
    }

    public subscript<Element>(
        dynamicMember member: KeyPath<Child._ViewMembers, IdentifiedArrayOf<Element>>
    ) -> CollectionProjection<Element>
    where Element: FeatureStateProtocol & Identifiable & Equatable {
        _projection()[dynamicMember: member]
    }

    /// Sends a child action, embedding it into the parent action and dispatching it through
    /// the parent.
    ///
    /// To hand off to a child view that takes a `(ChildAction) -> Void` callback, wrap in a
    /// closure (the returned ``EventTask`` is discarded):
    ///
    /// ```swift
    /// ChildView(action: { scoped.sendViewEvent($0) })
    /// ```
    ///
    /// - Parameter action: The child action to embed and dispatch.
    /// - Returns: The parent's ``EventTask`` for the dispatched action.
    @discardableResult
    public func sendViewEvent(_ action: ChildAction) -> EventTask {
        _send(action)
    }

    #if canImport(CasePaths)
        /// Returns a binding whose getter reads the given projected member (registering
        /// access like any read) and whose setter sends the new value embedded as a child
        /// action.
        ///
        /// - Parameters:
        ///   - member: A projected member of the child state to read.
        ///   - embed: A case key path that wraps the new value into a child action.
        /// - Returns: A two-way binding over the child slice.
        public func binding<Value: Equatable>(
            _ member: KeyPath<Child._ViewMembers, Value>,
            sending embed: CaseKeyPath<ChildAction, Value>
        ) -> Binding<Value> {
            let projection = self._projection
            let send = self._send
            return Binding(
                get: { projection()[dynamicMember: member] },
                set: { newValue in _ = send(embed(newValue)) }
            )
        }
    #endif
}

#if canImport(CasePaths)
    extension ViewModel where Action: CasePathable {
        /// Projects this view model onto a nested child feature state and a child action
        /// space.
        ///
        /// The child action is embedded into this feature's action with `actionCasePath`.
        /// This is sugar over the closure-based ``scope(state:action:)-swift.method``
        /// overload.
        ///
        /// - Parameters:
        ///   - stateKeyPath: A projected member whose type is itself `@FeatureState`.
        ///   - actionCasePath: A case key path that embeds the child action into this
        ///     feature's action.
        /// - Returns: A ``ScopedViewModel`` over the child state and action.
        public func scope<ChildState: FeatureStateProtocol, ChildAction>(
            state stateKeyPath: KeyPath<State._ViewMembers, ChildState>,
            action actionCasePath: CaseKeyPath<Action, ChildAction>
        ) -> ScopedViewModel<ChildState, ChildAction> {
            scope(state: stateKeyPath, action: { actionCasePath($0) })
        }
    }

    extension ScopedViewModel {
        /// Projects this scope onto a grandchild feature state and action space, composing
        /// through the parent.
        ///
        /// - Parameters:
        ///   - stateKeyPath: A projected member of the child whose type is itself
        ///     `@FeatureState`.
        ///   - embed: A case key path that embeds the grandchild action into the child
        ///     action.
        /// - Returns: A ``ScopedViewModel`` over the grandchild state and action.
        public func scope<GrandState: FeatureStateProtocol, GrandAction>(
            state stateKeyPath: KeyPath<Child._ViewMembers, GrandState>,
            action embed: CaseKeyPath<ChildAction, GrandAction>
        ) -> ScopedViewModel<GrandState, GrandAction> {
            let projection = self._projection
            let send = self._send
            return ScopedViewModel<GrandState, GrandAction>(
                projection: { projection()[dynamicMember: stateKeyPath] },
                send: { grandAction in send(embed(grandAction)) }
            )
        }
    }

    extension ViewModel where Action: CasePathable {
        /// Projects this view model onto the payload of an enum case of the state (via its
        /// generated case accessor), if that case is currently active.
        ///
        /// This is the primitive form; ``scope(state:action:fileID:line:)`` is trapping sugar
        /// over it for use inside a matched `switch` case. Reads are live: the returned scope
        /// re-extracts the payload from the current state on every access, so payload
        /// mutations are observed fine-grained. If the case deactivates while the scope is
        /// still held (at most one transitional render), reads serve the payload captured at
        /// creation — the runtime has already cancelled the departed case's effect tasks at
        /// that commit, so the snapshot renders stale payload but never live effects.
        ///
        /// Sends are embedded into this feature's action with `embed` and dispatched through
        /// this view model. A send can arrive after the case has deactivated; `When` drops
        /// the action when the case is inactive, and the core has already cancelled the
        /// child's path-prefix task bucket at case exit — a child effect's late `modify` is
        /// dropped silently. The interactor should still drop actions that no longer apply
        /// to the current state.
        ///
        /// - Parameters:
        ///   - member: The generated case accessor for an enum case whose payload is
        ///     `@FeatureState`.
        ///   - embed: A case key path that embeds the child action into this feature's
        ///     action.
        /// - Returns: A scope over the case's payload, or `nil` if the case is not active.
        public func scopeIfActive<ChildState: FeatureStateProtocol, ChildAction>(
            state member: KeyPath<State._ViewMembers, ChildState?>,
            action embed: CaseKeyPath<Action, ChildAction>
        ) -> ScopedViewModel<ChildState, ChildAction>? {
            let parent = projection
            let stateKeyPath = State._viewKeyPaths[member] as! KeyPath<State, ChildState?>
            let creationKey = parent.key.appending(member)
            // Register the slot's shape key even when inactive, so a view that got `nil`
            // re-renders when the case activates.
            parent.registrar.access(creationKey.structure)
            guard let snapshot = parent.read()[keyPath: stateKeyPath] else { return nil }
            return ScopedViewModel(
                projection: {
                    let parent = self.projection
                    let childKey = parent.key.appending(member)
                    parent.registrar.access(childKey.structure)
                    return FeatureProjection<ChildState>(
                        read: { parent.read()[keyPath: stateKeyPath] ?? snapshot },
                        registrar: parent.registrar,
                        key: childKey
                    )
                },
                send: { [self] childAction in sendViewEvent(embed(childAction)) }
            )
        }

        /// Projects this view model onto the payload of the currently active enum case of
        /// the state, trapping if the case is not active.
        ///
        /// Call this only inside a `switch` case that just matched the same case:
        ///
        /// ```swift
        /// switch viewModel.route {
        /// case .loading:
        ///     LoadingView()
        /// case .success:
        ///     SuccessView(model: viewModel.scope(state: \.success, action: \.success))
        /// }
        /// ```
        ///
        /// Body evaluation is synchronous on the main actor, so within a matched case this
        /// cannot trap. Use ``scopeIfActive(state:action:)`` when the case may legitimately
        /// be inactive.
        public func scope<ChildState: FeatureStateProtocol, ChildAction>(
            state member: KeyPath<State._ViewMembers, ChildState?>,
            action embed: CaseKeyPath<Action, ChildAction>,
            fileID: StaticString = #fileID,
            line: UInt = #line
        ) -> ScopedViewModel<ChildState, ChildAction> {
            guard let scoped = scopeIfActive(state: member, action: embed) else {
                fatalError(
                    """
                    scope(state:action:) at \(fileID):\(line): scoped into case '\(member)' \
                    while it is not the active case of the state. Call this only inside a \
                    switch case that matched the same case, or use scopeIfActive(state:action:).
                    """
                )
            }
            return scoped
        }
    }

    extension ScopedViewModel {
        /// Projects this scope onto the payload of an enum case of the child state (via its
        /// generated case accessor), if active.
        /// See ``ViewModel/scopeIfActive(state:action:)``.
        public func scopeIfActive<CaseState: FeatureStateProtocol, CaseAction>(
            state member: KeyPath<Child._ViewMembers, CaseState?>,
            action embed: CaseKeyPath<ChildAction, CaseAction>
        ) -> ScopedViewModel<CaseState, CaseAction>? {
            let parentProjection = self._projection
            let stateKeyPath = Child._viewKeyPaths[member] as! KeyPath<Child, CaseState?>
            let creationParent = parentProjection()
            // Register the slot's shape key even when inactive (see ViewModel.scopeIfActive).
            creationParent.registrar.access(creationParent.key.appending(member).structure)
            guard let snapshot = creationParent.read()[keyPath: stateKeyPath] else {
                return nil
            }
            let send = self._send
            return ScopedViewModel<CaseState, CaseAction>(
                projection: {
                    let parent = parentProjection()
                    let childKey = parent.key.appending(member)
                    parent.registrar.access(childKey.structure)
                    return FeatureProjection<CaseState>(
                        read: { parent.read()[keyPath: stateKeyPath] ?? snapshot },
                        registrar: parent.registrar,
                        key: childKey
                    )
                },
                send: { caseAction in send(embed(caseAction)) }
            )
        }

        /// Projects this scope onto the payload of the currently active enum case of the
        /// child state, trapping if the case is not active.
        /// See ``ViewModel/scope(state:action:fileID:line:)``.
        public func scope<CaseState: FeatureStateProtocol, CaseAction>(
            state member: KeyPath<Child._ViewMembers, CaseState?>,
            action embed: CaseKeyPath<ChildAction, CaseAction>,
            fileID: StaticString = #fileID,
            line: UInt = #line
        ) -> ScopedViewModel<CaseState, CaseAction> {
            guard let scoped = scopeIfActive(state: member, action: embed) else {
                fatalError(
                    """
                    scope(state:action:) at \(fileID):\(line): scoped into case '\(member)' \
                    while it is not the active case of the child slice. Call this only inside \
                    a switch case that matched the same case, or use scopeIfActive(state:action:).
                    """
                )
            }
            return scoped
        }
    }
#endif

extension ViewModel {
    /// Projects this view model onto a nested child feature state and a child action space,
    /// mapping child actions into parent actions with a closure.
    ///
    /// This is the general form and has no `CasePathable` requirement; the case-path
    /// ``scope(state:action:)-swift.method`` overload is sugar over it. Reach for it when the
    /// parent action is not `@CasePathable`, or when the mapping is not a plain case
    /// embedding.
    ///
    /// - Parameters:
    ///   - stateKeyPath: A projected member whose type is itself `@FeatureState`.
    ///   - embed: A closure that maps a child action into this feature's action.
    /// - Returns: A ``ScopedViewModel`` over the child state and action.
    public func scope<ChildState: FeatureStateProtocol, ChildAction>(
        state stateKeyPath: KeyPath<State._ViewMembers, ChildState>,
        action embed: @escaping @MainActor (ChildAction) -> Action
    ) -> ScopedViewModel<ChildState, ChildAction> {
        ScopedViewModel(
            projection: { [self] in projection[dynamicMember: stateKeyPath] },
            send: { [self] childAction in sendViewEvent(embed(childAction)) }
        )
    }

    /// Projects this view model onto a read-only child feature state, for child views that
    /// display state but send no actions.
    ///
    /// - Parameter stateKeyPath: A projected member whose type is itself `@FeatureState`.
    /// - Returns: A ``ScopedViewModel`` whose action type is `Never`.
    public func scope<ChildState: FeatureStateProtocol>(
        state stateKeyPath: KeyPath<State._ViewMembers, ChildState>
    ) -> ScopedViewModel<ChildState, Never> {
        ScopedViewModel(
            projection: { [self] in projection[dynamicMember: stateKeyPath] },
            send: { (_: Never) in EventTask(rawValue: nil) }
        )
    }
}
