import Foundation
import Lattice

/// The state the arithmetic stubs write: the latest result, and the name of every stub whose
/// effect ran, in the order the effects ran.
@FeatureState
struct ArithmeticState: Equatable {
    var value = 0
    var performed: [String] = []
}

/// Takes an input and doubles it; its effect records "double".
struct DoubleInteractor: Interactor, Sendable {
    typealias State = ArithmeticState
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(state: inout ArithmeticState, action: Int, effects: Effects<ArithmeticState, Int>) {
        state.value = action * 2
        effects.perform { try effects.modify { $0.performed.append("double") } }
    }
}

/// Takes an input and triples it; its effect records "triple".
struct TripleInteractor: Interactor, Sendable {
    typealias State = ArithmeticState
    typealias Action = Int

    var body: some InteractorOf<Self> { self }

    func interact(state: inout ArithmeticState, action: Int, effects: Effects<ArithmeticState, Int>) {
        state.value = action * 3
        effects.perform { try effects.modify { $0.performed.append("triple") } }
    }
}

/// A test model over an arithmetic interactor, from the initial state. It forwards the caller's
/// location, so the reports the model makes at its creation point at the test.
@available(iOS 26, macOS 26, watchOS 26, *)
func makeArithmeticModel<I: Interactor<ArithmeticState, Int>>(
    _ interactor: sending I,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> TestModel<Feature<Int, ArithmeticState>> {
    await TestModel(
        initialState: ArithmeticState(),
        feature: Feature(interactor: interactor),
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}
