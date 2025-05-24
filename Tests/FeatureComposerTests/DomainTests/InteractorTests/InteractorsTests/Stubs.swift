import Combine
import FeatureComposer

/// Takes an input and doubles it
struct DoubleInteractor: Interactor {
    typealias State = Int
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
    typealias State = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(_ upstream: AnyPublisher<Int, Never>) -> AnyPublisher<Int, Never> {
        upstream
            .map { $0 * 3 }
            .eraseToAnyPublisher()
    }
}
