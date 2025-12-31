import Foundation

extension Interactors {
    public enum Conditional<First: Interactor, Second: Interactor<First.DomainState, First.Action>>: Interactor, @unchecked Sendable
    where First.DomainState: Sendable, First.Action: Sendable {
        case first(First)
        case second(Second)

        public var body: some Interactor<First.DomainState, First.Action> { self }

        public func interact(_ upstream: AsyncStream<First.Action>) -> AsyncStream<First.DomainState> {
            switch self {
            case .first(let first):
                return first.interact(upstream)
            case .second(let second):
                return second.interact(upstream)
            }
        }
    }
}
