import Combine
import DomainArchitecture

/// Takes an input and doubles it
struct DoubleInteractor: Interactor {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(_ upstream: AnyPublisher<Int, Never>) -> AnyPublisher<Int, Never> {
        upstream
            .map { $0 * 2 }
            .eraseToAnyPublisher()
    }
}

/// Takes an input and triples it
struct TripleInteractor: Interactor {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(_ upstream: AnyPublisher<Int, Never>) -> AnyPublisher<Int, Never> {
        upstream
            .map { $0 * 3 }
            .eraseToAnyPublisher()
    }
}
