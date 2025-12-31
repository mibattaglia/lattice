import AsyncAlgorithms
import CasePaths
import Foundation

extension Interactor where Self: Sendable {
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
    public struct When<Parent: Interactor & Sendable, Child: Interactor & Sendable>: Interactor, Sendable
    where Parent.DomainState: Sendable, Parent.Action: Sendable,
          Child.DomainState: Sendable, Child.Action: Sendable {
        public typealias DomainState = Parent.DomainState
        public typealias Action = Parent.Action

        enum StatePath: @unchecked Sendable {
            case keyPath(WritableKeyPath<Parent.DomainState, Child.DomainState>)
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
