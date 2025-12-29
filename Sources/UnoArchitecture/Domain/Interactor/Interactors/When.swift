import CasePaths
import Combine
import Foundation

// MARK: - Interactor Extension

extension Interactor {
    /// Embeds a child interactor that runs on a subset of this interactor's domain.
    ///
    /// The child interactor receives child actions extracted from parent actions,
    /// and its state changes are fed back as state change actions to this interactor.
    ///
    /// Use this modifier when the child state is a **struct property** of the parent state.
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///   Interact(initialValue: ParentState()) { state, action in
    ///     switch action {
    ///     case .childStateChanged(let childState):
    ///       state.child = childState
    ///       return .state
    ///     // ...
    ///     }
    ///   }
    ///   .when(stateIs: \.child, actionIs: \.child, stateAction: \.childStateChanged) {
    ///     ChildInteractor()
    ///   }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - toChildState: A writable key path from parent state to a property containing child state.
    ///   - toChildAction: A case path from parent action to a case containing child actions.
    ///   - toStateAction: A case path that creates parent actions from child state updates.
    ///   - child: An interactor that will be invoked with child actions against child state.
    /// - Returns: An interactor that wraps this interactor with child embedding.
    public func when<ChildState, ChildAction, Child: Interactor>(
        stateIs toChildState: WritableKeyPath<DomainState, ChildState>,
        actionIs toChildAction: CaseKeyPath<Action, ChildAction>,
        stateAction toStateAction: CaseKeyPath<Action, ChildState>,
        @InteractorBuilder<ChildState, ChildAction> run child: () -> Child
    ) -> Interactors.When<Self, Child>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.When(
            parent: self,
            toChildState: .keyPath(toChildState),
            toChildAction: AnyCasePath(toChildAction),
            toStateAction: AnyCasePath(toStateAction),
            child: child()
        )
    }

    /// Embeds a child interactor that runs on a subset of this interactor's domain.
    ///
    /// Use this modifier when the child state is an **enum case** of the parent state.
    /// This pattern is useful for mutually-exclusive features (e.g., logged in vs. logged out).
    ///
    /// ```swift
    /// var body: some InteractorOf<Self> {
    ///   Interact(initialValue: .loggedOut(LoggedOut.State())) { state, action in
    ///     switch action {
    ///     case .loggedInStateChanged(let childState):
    ///       state = .loggedIn(childState)
    ///       return .state
    ///     // ...
    ///     }
    ///   }
    ///   .when(stateIs: \.loggedIn, actionIs: \.loggedIn, stateAction: \.loggedInStateChanged) {
    ///     LoggedInInteractor()
    ///   }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - toChildState: A case path from parent state to a case containing child state.
    ///   - toChildAction: A case path from parent action to a case containing child actions.
    ///   - toStateAction: A case path that creates parent actions from child state updates.
    ///   - child: An interactor that will be invoked with child actions against child state.
    /// - Returns: An interactor that wraps this interactor with child embedding.
    public func when<ChildState, ChildAction, Child: Interactor>(
        stateIs toChildState: CaseKeyPath<DomainState, ChildState>,
        actionIs toChildAction: CaseKeyPath<Action, ChildAction>,
        stateAction toStateAction: CaseKeyPath<Action, ChildState>,
        @InteractorBuilder<ChildState, ChildAction> run child: () -> Child
    ) -> Interactors.When<Self, Child>
    where Child.DomainState == ChildState, Child.Action == ChildAction {
        Interactors.When(
            parent: self,
            toChildState: .casePath(AnyCasePath(toChildState)),
            toChildAction: AnyCasePath(toChildAction),
            toStateAction: AnyCasePath(toStateAction),
            child: child()
        )
    }
}

// MARK: - When Interactor

extension Interactors {
    /// An ``Interactor`` that embeds a child interactor in a parent domain.
    ///
    /// ``When`` wraps a parent interactor and augments its action stream with child state
    /// changes. This allows child interactors to be composed with parent interactors while
    /// maintaining type safety.
    ///
    /// You typically create a ``When`` using the `.when()` modifier on an interactor:
    ///
    /// ```swift
    /// Interact(initialValue: ParentState()) { state, action in
    ///   switch action {
    ///   case .childStateChanged(let childState):
    ///     state.child = childState
    ///     return .state
    ///   // ...
    ///   }
    /// }
    /// .when(stateIs: \.child, actionIs: \.child, stateAction: \.childStateChanged) {
    ///   ChildInteractor()
    /// }
    /// ```
    ///
    /// The modifier intercepts child actions, routes them to the child interactor, and injects
    /// the resulting state changes as parent actions. This enables child interactors to be
    /// isolated from the parent domain while still propagating their state changes.
    public struct When<Parent: Interactor, Child: Interactor>: Interactor {
        public typealias DomainState = Parent.DomainState
        public typealias Action = Parent.Action

        enum StatePath {
            case keyPath(WritableKeyPath<Parent.DomainState, Child.DomainState>)
            case casePath(AnyCasePath<Parent.DomainState, Child.DomainState>)
        }

        let parent: Parent
        let toChildState: StatePath
        let toChildAction: AnyCasePath<Parent.Action, Child.Action>
        let toStateAction: AnyCasePath<Parent.Action, Child.DomainState>
        let child: Child

        init(
            parent: Parent,
            toChildState: StatePath,
            toChildAction: AnyCasePath<Parent.Action, Child.Action>,
            toStateAction: AnyCasePath<Parent.Action, Child.DomainState>,
            child: Child
        ) {
            self.parent = parent
            self.toChildState = toChildState
            self.toChildAction = toChildAction
            self.toStateAction = toStateAction
            self.child = child
        }

        public var body: some Interactor<DomainState, Action> { self }

        public func interact(
            _ upstream: AnyPublisher<Action, Never>
        ) -> AnyPublisher<DomainState, Never> {
            let childActionSubject = PassthroughSubject<Child.Action, Never>()

            // Child state emissions become state change actions (handles async children like Debounce)
            let childStateActions = childActionSubject
                .interact(with: child)
                .map { [toStateAction] state in toStateAction.embed(state) }

            // Filter child actions from upstream - route them to child instead
            let nonChildActions = upstream
                .handleEvents(
                    receiveOutput: { [toChildAction] action in
                        if let childAction = toChildAction.extract(from: action) {
                            childActionSubject.send(childAction)
                        }
                    },
                    receiveCompletion: { _ in childActionSubject.send(completion: .finished) },
                    receiveCancel: { childActionSubject.send(completion: .finished) }
                )
                .filter { [toChildAction] action in
                    toChildAction.extract(from: action) == nil
                }

            // Merge non-child actions with async child state change actions
            return nonChildActions
                .merge(with: childStateActions)
                .interact(with: parent)
                .eraseToAnyPublisher()
        }
    }
}
