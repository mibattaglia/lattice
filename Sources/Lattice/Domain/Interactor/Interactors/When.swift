import Foundation

#if canImport(CasePaths)
    import CasePaths
#endif

#if canImport(CasePaths)
    extension Interactors {
        /// Embeds a child interactor in a parent domain.
        ///
        /// `When` allows you to scope a parent domain to a child domain, running a child
        /// interactor on that subset. This enables modular feature composition by breaking
        /// large features into smaller, testable units.
        ///
        /// ## Usage with KeyPath (struct state)
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///     Interactors.When(state: \.counter, action: \.counter) {
        ///         CounterInteractor()
        ///     }
        ///     Interact { state, action in
        ///         // Additional parent logic
        ///     }
        /// }
        /// ```
        ///
        /// ## Usage with CaseKeyPath (enum state)
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///     Interactors.When(state: \.loaded, action: \.loaded) {
        ///         LoadedInteractor()
        ///     }
        /// }
        /// ```
        ///
        /// ## How It Works
        ///
        /// 1. Actions matching `toChildAction` are extracted and forwarded to the child.
        /// 2. The child receives an ``Effects`` handle pulled back through the state and
        ///    action lenses, with this node's state path appended as a `GraphPath` component.
        ///    Child effects mutate parent state through the lens via `modify`.
        /// 3. For case-path state, child state is embedded back into parent state after the
        ///    child's synchronous update.
        /// 4. Non-matching actions pass through untouched.
        ///
        /// ## Dismissal semantics
        ///
        /// If the parent's enum has left the child's case (or the scoped optional is `nil`)
        /// by the time a child effect calls `modify`, the mutation is **dropped silently**
        /// and the child subtree's in-flight tasks are cancelled, so effects that outlive
        /// a dismissed child never write stale state back into the parent.
        public struct When<ParentState, ParentAction, Child: Interactor>: Interactor {
            public typealias DomainState = ParentState
            public typealias Action = ParentAction

            enum StatePath {
                case keyPath(WritableKeyPath<ParentState, Child.DomainState>)
                case casePath(AnyCasePath<ParentState, Child.DomainState>)
            }

            private let toChildState: StatePath
            private let toChildAction: AnyCasePath<ParentAction, Child.Action>
            private let pathComponent: GraphPath.Component
            private let child: Child

            init(
                toChildState: StatePath,
                toChildAction: AnyCasePath<ParentAction, Child.Action>,
                pathComponent: GraphPath.Component,
                child: Child
            ) {
                self.toChildState = toChildState
                self.toChildAction = toChildAction
                self.pathComponent = pathComponent
                self.child = child
            }

            /// Creates a scoped interactor for struct state using a writable key path.
            ///
            /// - Parameters:
            ///   - toChildState: A writable key path from parent state to child state.
            ///   - toChildAction: A case key path from parent action to child actions.
            ///   - child: A closure that returns the child interactor.
            public init<ChildState, ChildAction>(
                state toChildState: WritableKeyPath<ParentState, ChildState>,
                action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
                @InteractorBuilder<ChildState, ChildAction> child: () -> Child
            ) where ChildState == Child.DomainState, ChildAction == Child.Action {
                self.init(
                    toChildState: .keyPath(toChildState),
                    toChildAction: AnyCasePath(toChildAction),
                    pathComponent: .keyPath(toChildState),
                    child: child()
                )
            }

            /// Creates a scoped interactor for enum state using a case key path.
            ///
            /// - Parameters:
            ///   - toChildState: A case key path from parent state to child state.
            ///   - toChildAction: A case key path from parent action to child actions.
            ///   - child: A closure that returns the child interactor.
            public init<ChildState, ChildAction>(
                state toChildState: CaseKeyPath<ParentState, ChildState>,
                action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
                @InteractorBuilder<ChildState, ChildAction> child: () -> Child
            ) where ChildState == Child.DomainState, ChildAction == Child.Action {
                self.init(
                    toChildState: .casePath(AnyCasePath(toChildState)),
                    toChildAction: AnyCasePath(toChildAction),
                    // CaseKeyPath is a KeyPath; its identity is the structural component.
                    pathComponent: .keyPath(toChildState),
                    child: child()
                )
            }

            public var body: some Interactor<ParentState, ParentAction> { self }

            /// The imperative-effect pathway: the child receives an ``Effects`` handle pulled
            /// back through the state and action lenses, with this node's state path appended
            /// as a `GraphPath` component. Child effects mutate parent state through the lens
            /// via `modify`.
            ///
            /// ## Dismissal semantics
            ///
            /// If the parent's enum has left the child's case (or the scoped optional is
            /// `nil`) by the time a child effect calls `modify`, the mutation is **dropped
            /// silently** and the child subtree's in-flight tasks are cancelled, so effects
            /// that outlive a dismissed child never write stale state back into the parent.
            /// Task cancellation for the *transition* into absence is the core's job
            /// (transition detection in the commit funnel), not `When`'s.
            public func interact(
                state: inout ParentState,
                action: ParentAction,
                effects: Effects<ParentState, ParentAction>
            ) {
                guard let childAction = toChildAction.extract(from: action) else {
                    return
                }

                switch toChildState {
                case .keyPath(let keyPath):
                    let childEffects = effects.scoped(
                        state: keyPath,
                        action: toChildAction,
                        component: pathComponent
                    )
                    child.interact(
                        state: &state[keyPath: keyPath],
                        action: childAction,
                        effects: childEffects
                    )

                case .casePath(let casePath):
                    guard var childState = casePath.extract(from: state) else {
                        return
                    }
                    let childEffects = effects.scoped(
                        state: casePath,
                        action: toChildAction,
                        component: pathComponent
                    )
                    child.interact(state: &childState, action: childAction, effects: childEffects)
                    state = casePath.embed(childState)
                }
            }
        }
    }
#endif

#if canImport(CasePaths)
    /// Convenience alias for `Interactors.When`.
    public typealias WhenInteractor<ParentState, ParentAction, Child: Interactor> =
        Interactors.When<ParentState, ParentAction, Child>

    // MARK: - Interactor Modifier

    extension Interactor {
        /// Scopes a child interactor to a subset of state and actions.
        ///
        /// Use `when` to embed a child interactor that operates on a portion of the parent's
        /// state and handles a subset of actions.
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///     Interact { state, action in
        ///         // Parent logic
        ///     }
        ///     .when(state: \.child, action: \.child) {
        ///         ChildInteractor()
        ///     }
        /// }
        /// ```
        ///
        /// - Parameters:
        ///   - toChildState: A writable key path from parent state to child state.
        ///   - toChildAction: A case key path from parent action to child actions.
        ///   - child: A closure that returns the child interactor.
        /// - Returns: A combined interactor that handles both parent and child domains.
        public func when<ChildState, ChildAction, Child: Interactor>(
            state toChildState: WritableKeyPath<DomainState, ChildState>,
            action toChildAction: CaseKeyPath<Action, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) -> Interactors.Merge<Interactors.When<DomainState, Action, Child>, Self>
        where Child.DomainState == ChildState, Child.Action == ChildAction {
            Interactors.Merge(
                Interactors.When(state: toChildState, action: toChildAction, child: child),
                self
            )
        }

        /// Scopes a child interactor to a subset of state and actions (enum state variant).
        ///
        /// Use `when` to embed a child interactor that operates on a portion of the parent's
        /// state and handles a subset of actions. This variant uses a case key path for
        /// enum-based state.
        ///
        /// ```swift
        /// var body: some InteractorOf<Self> {
        ///     Interact { state, action in
        ///         // Parent logic
        ///     }
        ///     .when(state: \.loaded, action: \.loaded) {
        ///         LoadedInteractor()
        ///     }
        /// }
        /// ```
        ///
        /// - Parameters:
        ///   - toChildState: A case key path from parent state to child state.
        ///   - toChildAction: A case key path from parent action to child actions.
        ///   - child: A closure that returns the child interactor.
        /// - Returns: A combined interactor that handles both parent and child domains.
        public func when<ChildState, ChildAction, Child: Interactor>(
            state toChildState: CaseKeyPath<DomainState, ChildState>,
            action toChildAction: CaseKeyPath<Action, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) -> Interactors.Merge<Interactors.When<DomainState, Action, Child>, Self>
        where Child.DomainState == ChildState, Child.Action == ChildAction {
            Interactors.Merge(
                Interactors.When(state: toChildState, action: toChildAction, child: child),
                self
            )
        }
    }
#endif
