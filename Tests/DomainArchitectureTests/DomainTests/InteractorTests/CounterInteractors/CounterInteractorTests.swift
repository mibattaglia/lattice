import Combine
import Foundation
import Testing

@testable import DomainArchitecture

@Suite
final class CounterInteractorTests {
    private let subject = PassthroughSubject<CounterInteractor.Action, Never>()
    private var cancellables: Set<AnyCancellable> = []

    private let counterInteractor = CounterInteractor()

    @Test func increment() {
        let expected: [CounterInteractor.DomainState] = [
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

        for _ in 1..<4 {
            subject.send(.increment)
        }
        subject.send(completion: .finished)
    }

    @Test func decrement() {
        let expected: [CounterInteractor.DomainState] = [
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
            .init(count: 2),
            .init(count: 1),
            .init(count: 0),
        ]

        counterInteractor
            .interact(subject.eraseToAnyPublisher())
            .collect()
            .sink { actual in
                #expect(actual == expected)
            }
            .store(in: &cancellables)

        for _ in 1..<4 {
            subject.send(.increment)
        }
        for _ in 1..<4 {
            subject.send(.decrement)
        }
        subject.send(completion: .finished)
    }

    @Test func reset() {
        let expected: [CounterInteractor.DomainState] = [
            .init(count: 0),
            .init(count: 1),
            .init(count: 2),
            .init(count: 3),
            .init(count: 0),
        ]

        counterInteractor
            .interact(subject.eraseToAnyPublisher())
            .collect()
            .sink { actual in
                #expect(actual == expected)
            }
            .store(in: &cancellables)

        for _ in 1..<4 {
            subject.send(.increment)
        }
        subject.send(.reset)
        subject.send(completion: .finished)
    }
}
