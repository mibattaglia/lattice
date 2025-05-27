import Combine
import Foundation

extension Interactors {
    public enum Conditional<First: Interactor, Second: Interactor<First.DomainState, First.Action>>: Interactor {
        case first(First)
        case second(Second)

        public var body: some Interactor<First.DomainState, First.Action> { self }

        public func interact(
            _ upstream: AnyPublisher<First.Action, Never>
        ) -> AnyPublisher<First.DomainState, Never> {
            switch self {
            case .first(let first):
                return first.interact(upstream)
            case .second(let second):
                return second.interact(upstream)
            }
        }
    }
}
