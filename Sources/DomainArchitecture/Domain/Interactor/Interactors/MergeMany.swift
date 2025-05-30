import Combine
import Foundation

extension Interactors {
    public struct MergeMany<Element: Interactor>: Interactor {
        private let interactors: [Element]

        public init(interactors: [Element]) {
            self.interactors = interactors
        }

        public var body: some Interactor<Element.DomainState, Element.Action> { self }

        public func interact(
            _ upstream: AnyPublisher<Element.Action, Never>
        ) -> AnyPublisher<Element.DomainState, Never> {
            upstream
                .flatMap { event in
                    interactors
                        .publisher
                        .flatMap(maxPublishers: .max(1)) { interactor in
                            interactor.interact(Just(event).eraseToAnyPublisher())
                        }
                }
                .eraseToAnyPublisher()
        }
    }
}
