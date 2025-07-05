import Combine
import Foundation

/// An ``Interactor`` that fans an incoming action out to *many* interactors and merges their
/// state emissions into a single stream.
///
/// This type backs the variadic and array overloads of ``InteractorBuilder``. It sequentially
/// publishes the upstream action to each child interactor and combines their resulting state
/// publishers using two levels of `flatMap`:
///
/// 1. The **outer** `flatMap` reacts to each incoming `Action`, creating a new inner pipeline that
///    targets all child interactors.
/// 2. The **inner** `flatMap(maxPublishers: .max(1))` applies *back-pressure* (see Matt Neuburg's
///    excellent article on [`flatMap`](https://www.apeth.com/UnderstandingCombine/operators/operatorsTransformersBlockers/operatorsflatmap.html)).
///    By limiting `maxPublishers` to **one**, we guarantee that only a single child interactor is
///    processing the current action at any given time. This keeps the order deterministic and
///    prevents value loss that can occur when multiple inner publishers emit concurrently.
///
/// `MergeMany` serializes the work across its children while still merging their
/// outputs into a single, interleaved state stream.
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
