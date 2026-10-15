import Foundation
import Lattice

/// The state the arithmetic stubs write: the latest result, and the name of every stub whose
/// effect ran, in the order the effects ran.
@FeatureState
struct ArithmeticState: Equatable {
    var value = 0
    var effectLog: [String] = []
}

/// Takes an input and doubles it; its effect records "double".
struct DoubleInteractor: Interactor, Sendable {
    typealias State = ArithmeticState
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(state: inout ArithmeticState, action: Int, effects: Effects<ArithmeticState, Int>) {
        state.value = action * 2
        effects.perform { try effects.modify { $0.effectLog.append("double") } }
    }
}

/// Takes an input and triples it; its effect records "triple".
struct TripleInteractor: Interactor, Sendable {
    typealias State = ArithmeticState
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(state: inout ArithmeticState, action: Int, effects: Effects<ArithmeticState, Int>) {
        state.value = action * 3
        effects.perform { try effects.modify { $0.effectLog.append("triple") } }
    }
}
