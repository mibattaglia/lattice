import Combine
import CombineSchedulers
import Foundation
import Testing

@testable import DomainArchitecture

@Suite
final class MergeManyTests {
    private var cancellables: Set<AnyCancellable> = []
    private let subject = PassthroughSubject<Int, Never>()

    @Test
    func mergeManyInOrder_SameType() async {
        let many = Interactors.MergeMany(
            interactors: [
                DoubleInteractor(),
                DoubleInteractor(),
                DoubleInteractor(),
            ]
        )
        let input = 4

        await confirmation { confirmation in
            many
                .interact(Just(input).eraseToAnyPublisher())
                .collect()
                .sink { actual in
                    #expect(actual == [8, 8, 8])
                    confirmation()
                }
                .store(in: &cancellables)
        }
    }

    @Test
    func mergeManyInOrder_TypeErased() async {
        let many = Interactors.MergeMany(
            interactors: [
                DoubleInteractor().eraseToAnyInteractor(),
                TripleInteractor().eraseToAnyInteractor(),
                DoubleInteractor().eraseToAnyInteractor(),
            ]
        )
        let input = 4

        await confirmation { confirmation in
            many
                .interact(Just(input).eraseToAnyPublisher())
                .collect()
                .sink { actual in
                    #expect(actual == [8, 12, 8])
                    confirmation()
                }
                .store(in: &cancellables)
        }
    }
}
