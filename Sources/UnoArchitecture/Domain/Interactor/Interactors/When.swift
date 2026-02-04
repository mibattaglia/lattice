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
    /// 1. Actions matching `toChildAction` are extracted and forwarded to the child
    /// 2. Child processes these actions and mutates its portion of state
    /// 3. For casePath state, child state is embedded back into parent state
    /// 4. Child emissions are mapped to parent action space
    /// 5. Non-matching actions pass through with `.none` emission
    public struct When<ParentState: Sendable, ParentAction: Sendable, Child: Interactor & Sendable>:
        Interactor, Sendable
    where Child.DomainState: Sendable, Child.Action: Sendable {
        public typealias DomainState = ParentState
        public typealias Action = ParentAction

        enum StatePath: @unchecked Sendable {
            case keyPath(WritableKeyPath<ParentState, Child.DomainState>)
            case casePath(AnyCasePath<ParentState, Child.DomainState>)
        }

        private let toChildState: StatePath
        private let toChildAction: AnyCasePath<ParentAction, Child.Action>
        private let child: Child

        init(
            toChildState: StatePath,
            toChildAction: AnyCasePath<ParentAction, Child.Action>,
            child: Child
        ) {
            self.toChildState = toChildState
            self.toChildAction = toChildAction
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
                child: child()
            )
        }

        public var body: some Interactor<ParentState, ParentAction> { self }

        public func interact(state: inout ParentState, action: ParentAction) -> Emission<ParentAction> {
            guard let childAction = toChildAction.extract(from: action) else {
                return .none
            }

            switch toChildState {
            case .keyPath(let keyPath):
                let childEmission = child.interact(state: &state[keyPath: keyPath], action: childAction)
                return childEmission.map { [toChildAction] in toChildAction.embed($0) }

            case .casePath(let casePath):
                guard var childState = casePath.extract(from: state) else {
                    return .none
                }
                defer { state = casePath.embed(childState) }
                let childEmission = child.interact(state: &childState, action: childAction)
                return childEmission.map { [toChildAction] in toChildAction.embed($0) }
            }
        }
    }
}
#endif

#if canImport(CasePaths)
/// Convenience alias for `Interactors.When`.
public typealias WhenInteractor<ParentState: Sendable, ParentAction: Sendable, Child: Interactor & Sendable> =
    Interactors.When<ParentState, ParentAction, Child>
where Child.DomainState: Sendable, Child.Action: Sendable

// MARK: - Interactor Modifier

extension Interactor where Self: Sendable {
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
    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
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
    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
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
