import Combine
import CombineSchedulers
import Foundation
import Testing

@testable import UnoArchitecture

@Suite
final class MergeTests {
    private var cancellables: Set<AnyCancellable> = []
    private let subject = PassthroughSubject<Int, Never>()

    @Test
    func mergeTwoRunsSequentially() async {
        let merge = Interactors.Merge(
            TripleInteractor(),
            DoubleInteractor()
        )
        await confirmation { confirmation in
            merge.interact(subject.eraseToAnyPublisher())
                .collect()
                .sink { actual in
                    #expect(actual == [9, 6])
                    confirmation()
                }
                .store(in: &cancellables)

            subject.send(3)
            subject.send(completion: .finished)
        }
    }
}
