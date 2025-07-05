import Combine
import Foundation

/// An ``Interactor`` that delivers each incoming action to **two** child interactors in
/// sequence and merges their state outputs.
///
/// This type underpins partial blocks built with the ``InteractorBuilder``'s two-parameter overload.
extension Interactors {
    public struct Merge<I0: Interactor, I1: Interactor<I0.DomainState, I0.Action>>: Interactor {
        private let i0: I0
        private let i1: I1

        public init(_ i0: I0, _ i1: I1) {
            self.i0 = i0
            self.i1 = i1
        }

        public var body: some Interactor<I0.DomainState, I0.Action> { self }

        public func interact(_ upstream: AnyPublisher<I0.Action, Never>) -> AnyPublisher<I0.DomainState, Never> {
            upstream
                .flatMap { event in
                    i0.interact(Just(event).eraseToAnyPublisher())
                        .append(i1.interact(Just(event).eraseToAnyPublisher()))
                }
                .eraseToAnyPublisher()
        }
    }
}
