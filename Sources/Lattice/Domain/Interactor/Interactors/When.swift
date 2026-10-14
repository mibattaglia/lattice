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
        ///     Interact { state, action, effects in
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
        /// 1. Actions matching `toChildAction` are extracted and forwarded to the child
        /// 2. The child mutates its portion of state; for case-path state, the child state is
        ///    embedded back into the parent state
        /// 3. The child's ``Effects`` handle is scoped: its sends are embedded into parent actions,
        ///    its modifications are written back into the parent state, and its anonymous effects
        ///    are auto-cancelled per child action case (`.child(.other)` does not cancel the
        ///    effects of `.child(.start)`)
        /// 4. Non-matching actions, and child actions while a case-path child is not active, are
        ///    ignored
        ///
        /// A case-path child whose case is no longer active changes nothing: its effects' sends
        /// and modifications are reported and dropped.
        public struct When<ParentState, ParentAction, Child: Interactor>: Interactor {
            public typealias State = ParentState
            public typealias Action = ParentAction

            enum StatePath {
                case keyPath(WritableKeyPath<ParentState, Child.State>)
                case casePath(AnyCasePath<ParentState, Child.State>)

                func extract(from parentState: ParentState) -> Child.State? {
                    switch self {
                    case .keyPath(let keyPath):
                        parentState[keyPath: keyPath]
                    case .casePath(let casePath):
                        casePath.extract(from: parentState)
                    }
                }

                func embed(_ parentState: inout ParentState, _ childState: Child.State) {
                    switch self {
                    case .keyPath(let keyPath):
                        parentState[keyPath: keyPath] = childState
                    case .casePath(let casePath):
                        parentState = casePath.embed(childState)
                    }
                }
            }

            private let toChildState: StatePath
            private let toChildAction: AnyCasePath<ParentAction, Child.Action>
            private let child: Child
            /// The key path or case key path this `When` was built with: scopes the child's
            /// `@EffectID` keys, so two `When`s over the same child type do not share effects.
            private let scopeEntry: AnyHashable

            init(
                toChildState: StatePath,
                toChildAction: AnyCasePath<ParentAction, Child.Action>,
                child: Child,
                scopeEntry: AnyHashable
            ) {
                self.toChildState = toChildState
                self.toChildAction = toChildAction
                self.child = child
                self.scopeEntry = scopeEntry
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
            ) where ChildState == Child.State, ChildAction == Child.Action {
                self.init(
                    toChildState: .keyPath(toChildState),
                    toChildAction: AnyCasePath(toChildAction),
                    child: child(),
                    scopeEntry: AnyHashable(toChildState)
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
            ) where ChildState == Child.State, ChildAction == Child.Action {
                self.init(
                    toChildState: .casePath(AnyCasePath(toChildState)),
                    toChildAction: AnyCasePath(toChildAction),
                    child: child(),
                    scopeEntry: AnyHashable(toChildState)
                )
            }

            public var body: some Interactor<ParentState, ParentAction> { self }

            public func interact(
                state: inout ParentState,
                action: ParentAction,
                effects: Effects<ParentState, ParentAction>
            ) {
                guard let childAction = toChildAction.extract(from: action) else { return }

                switch toChildState {
                case .keyPath(let keyPath):
                    let childEffects = scoped(effects, from: state[keyPath: keyPath], for: childAction)
                    child.interact(state: &state[keyPath: keyPath], action: childAction, effects: childEffects)

                case .casePath(let casePath):
                    guard var childState = casePath.extract(from: state) else { return }
                    let childEffects = scoped(effects, from: childState, for: childAction)
                    defer { state = casePath.embed(childState) }
                    child.interact(state: &childState, action: childAction, effects: childEffects)
                }
            }

            /// The child's handle, seeded with the child state the action is routed to. Scoping
            /// registers the child path `[tag(parentAction), tag(childAction)]` for auto-cancel.
            private func scoped(
                _ effects: Effects<ParentState, ParentAction>,
                from childState: Child.State,
                for childAction: Child.Action
            ) -> Effects<Child.State, Child.Action> {
                let toChildState = self.toChildState
                let toChildAction = self.toChildAction
                return effects.scope(
                    initialState: childState,
                    extract: { toChildState.extract(from: $0) },
                    embed: { toChildAction.embed($0) },
                    embedState: { toChildState.embed(&$0, $1) },
                    childTag: enumTag(childAction),
                    scopeEntry: scopeEntry
                )
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
        ///     Interact { state, action, effects in
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
            state toChildState: WritableKeyPath<State, ChildState>,
            action toChildAction: CaseKeyPath<Action, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) -> Interactors.Merge<Interactors.When<State, Action, Child>, Self>
        where Child.State == ChildState, Child.Action == ChildAction {
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
        ///     Interact { state, action, effects in
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
            state toChildState: CaseKeyPath<State, ChildState>,
            action toChildAction: CaseKeyPath<Action, ChildAction>,
            @InteractorBuilder<ChildState, ChildAction> child: () -> Child
        ) -> Interactors.Merge<Interactors.When<State, Action, Child>, Self>
        where Child.State == ChildState, Child.Action == ChildAction {
            Interactors.Merge(
                Interactors.When(state: toChildState, action: toChildAction, child: child),
                self
            )
        }
    }
#endif
