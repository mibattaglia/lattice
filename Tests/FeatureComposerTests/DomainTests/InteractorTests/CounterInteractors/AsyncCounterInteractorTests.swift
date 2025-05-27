import Combine
import CombineSchedulers
import Foundation
import Testing

@testable import FeatureComposer

@Suite
final class AsyncCounterInteractorTests {
    private let subject = PassthroughSubject<AsyncCounterInteractor.Action, Never>()
    private var cancellables: Set<AnyCancellable> = []

    private let counterInteractor: AsyncCounterInteractor
    private let scheduler = DispatchQueue.test

    init() {
        self.counterInteractor = AsyncCounterInteractor(
            scheduler: scheduler.eraseToAnyScheduler()
        )
    }

    @Test func asyncWork() async {
        let expected: [AsyncCounterInteractor.State] = [
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
        ]

        counterInteractor
            .interact(subject.eraseToAnyPublisher())
            .collect()
            .sink { actual in
                #expect(actual == expected)
            }
            .store(in: &cancellables)

        subject.send(.increment)
        subject.send(.async)
        await scheduler.advance(by: .seconds(0.5))
        subject.send(.increment)
        subject.send(completion: .finished)
    }
}
