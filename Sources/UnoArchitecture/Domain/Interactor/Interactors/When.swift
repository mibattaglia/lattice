import AsyncAlgorithms
import CasePaths
import Foundation

extension Interactor where Self: Sendable {
    /// Scopes a child interactor to a subset of state and actions.
    ///
    /// Use `when` to embed a child interactor that operates on a portion of the parent's
    /// state and handles a subset of actions. This enables modular feature composition.
    ///
    /// ## Usage with KeyPath (struct state)
    ///
    /// ```swift
    /// ParentInteractor()
    ///     .when(
    ///         stateIs: \.childState,
    ///         actionIs: \.childAction,
    ///         stateAction: \.setChildState
    ///     ) {
    ///         ChildInteractor()
    ///     }
    /// ```
    ///
    /// - Parameters:
    ///   - toChildState: KeyPath to the child state within parent state.
    ///   - toChildAction: CaseKeyPath to extract child actions from parent actions.
    ///   - toStateAction: CaseKeyPath to embed child state back into parent actions.
    ///   - child: A closure that returns the child interactor.
    /// - Returns: A `When` interactor that routes actions appropriately.
    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
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

    /// Scopes a child interactor to a subset of state and actions.
    ///
    /// Use `when` to embed a child interactor that operates on a portion of the parent's
    /// state and handles a subset of actions. This variant uses a CaseKeyPath for
    /// enum-based state.
    ///
    /// ## Usage with CaseKeyPath (enum state)
    ///
    /// ```swift
    /// ParentInteractor()
    ///     .when(
    ///         stateIs: \.loaded,
    ///         actionIs: \.loadedAction,
    ///         stateAction: \.setLoaded
    ///     ) {
    ///         LoadedInteractor()
    ///     }
    /// ```
    ///
    /// - Parameters:
    ///   - toChildState: CaseKeyPath to extract child state from parent enum state.
    ///   - toChildAction: CaseKeyPath to extract child actions from parent actions.
    ///   - toStateAction: CaseKeyPath to embed child state back into parent actions.
    ///   - child: A closure that returns the child interactor.
    /// - Returns: A `When` interactor that routes actions appropriately.
    public func when<ChildState, ChildAction, Child: Interactor & Sendable>(
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

extension Interactors {
    /// An interactor that scopes a child interactor to a subset of parent state and actions.
    ///
    /// `When` enables modular feature composition by routing specific actions to a child
    /// interactor and embedding the child's state changes back into the parent state.
    ///
    /// ## How It Works
    ///
    /// 1. Actions matching `toChildAction` are extracted and forwarded to the child
    /// 2. The child processes these actions and emits state changes
    /// 3. Child state changes are wrapped in `toStateAction` and sent to the parent
    /// 4. All other actions are handled directly by the parent interactor
    ///
    /// - Note: Use the `when(stateIs:actionIs:stateAction:run:)` method on any interactor
    ///   rather than constructing `When` directly.
    public struct When<Parent: Interactor & Sendable, Child: Interactor & Sendable>: Interactor, Sendable
    where
        Parent.DomainState: Sendable, Parent.Action: Sendable,
        Child.DomainState: Sendable, Child.Action: Sendable
    {
        public typealias DomainState = Parent.DomainState
        public typealias Action = Parent.Action

        /// Represents how to access child state from parent state.
        enum StatePath: @unchecked Sendable {
            /// Access via a writable key path (for struct state).
            case keyPath(WritableKeyPath<Parent.DomainState, Child.DomainState>)
            /// Access via a case path (for enum state).
            case casePath(AnyCasePath<Parent.DomainState, Child.DomainState>)
        }

        let parent: Parent
        let toChildState: StatePath
        let toChildAction: AnyCasePath<Parent.Action, Child.Action>
        let toStateAction: AnyCasePath<Parent.Action, Child.DomainState>
        let child: Child

        public var body: some Interactor<DomainState, Action> { self }

        public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<DomainState> {
            AsyncStream { continuation in
                let task = Task {
                    let childActionChannel = AsyncChannel<Child.Action>()
                    let (parentActionStream, parentCont) = AsyncStream<Action>.makeStream()

                    let childTask = Task {
                        for await childState in child.interact(childActionChannel.eraseToAsyncStream()).dropFirst() {
                            let stateAction = toStateAction.embed(childState)
                            parentCont.yield(stateAction)
                        }
                    }

                    let routingTask = Task {
                        for await action in upstream {
                            if let childAction = toChildAction.extract(from: action) {
                                await childActionChannel.send(childAction)
                            } else {
                                parentCont.yield(action)
                            }
                        }
                        childActionChannel.finish()
                        parentCont.finish()
                        // Do not await `childTask` here. Child interactors may be long-lived (e.g.
                        // observation streams) and waiting for them would prevent the parent action
                        // stream from completing, which can hang consumers waiting on parent states.
                        childTask.cancel()
                    }

                    for await state in parent.interact(parentActionStream) {
                        continuation.yield(state)
                    }

                    childTask.cancel()
                    routingTask.cancel()
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }
}

extension AsyncChannel {
    func eraseToAsyncStream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                for await element in self {
                    continuation.yield(element)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
