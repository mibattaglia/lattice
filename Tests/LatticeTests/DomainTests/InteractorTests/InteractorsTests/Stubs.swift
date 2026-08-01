import Lattice

/// Takes an input and doubles it
struct DoubleInteractor: Interactor {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(state: inout Int, action: Int, effects: Effects<Int, Int>) {
        state = action * 2
    }
}

/// Takes an input and triples it
struct TripleInteractor: Interactor {
    typealias DomainState = Int
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(state: inout Int, action: Int, effects: Effects<Int, Int>) {
        state = action * 3
    }
}
