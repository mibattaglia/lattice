import Combine
import Foundation
import Testing

@testable import FeatureComposer

@Suite
final class HotCounterInteractorTests {
    private let subject = PassthroughSubject<HotCounterInteractor.Action, Never>()
    private var cancellables: Set<AnyCancellable> = []

    private let counterInteractor = HotCounterInteractor()

    @Test func asyncWork() async {
        let expected: [HotCounterInteractor.State] = [
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 4),
            .init(count: 5),
        ]

        counterInteractor
            .interact(subject.eraseToAnyPublisher())
            .collect()
            .sink { actual in
                #expect(actual == expected)
            }
            .store(in: &cancellables)

        subject.send(.increment)

        let intPublisher = PassthroughSubject<Int, Never>()
        subject.send(.observe(intPublisher.eraseToAnyPublisher()))
        intPublisher.send(1)
        intPublisher.send(2)

        subject.send(.increment)
        intPublisher.send(completion: .finished)
        subject.send(completion: .finished)
    }
}
