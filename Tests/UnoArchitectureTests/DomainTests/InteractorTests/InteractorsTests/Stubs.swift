import UnoArchitecture

/// Takes an input and doubles it
struct DoubleInteractor: Interactor, Sendable {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(state: inout Int, action: Int) -> Emission<Int> {
        state = action * 2
        return .none
    }
}

/// Takes an input and triples it
struct TripleInteractor: Interactor, Sendable {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(state: inout Int, action: Int) -> Emission<Int> {
        state = action * 3
        return .none
    }
}
