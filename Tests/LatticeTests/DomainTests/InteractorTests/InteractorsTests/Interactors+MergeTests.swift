import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
struct MergeTests {
    @Test
    func mergeTwo() throws {
        var results: [Int] = []

        // TripleInteractor processes first: value = 3 * 3 = 9
        let triple = makeViewModel(TripleInteractor())
        triple.sendViewEvent(3)
        results.append(triple.value)

        // DoubleInteractor processes: value = 3 * 2 = 6
        let double = makeViewModel(DoubleInteractor())
        double.sendViewEvent(3)
        results.append(double.value)

        #expect(results == [9, 6])

        // Also verify merge calls both
        let merge = makeViewModel(Interactors.Merge(TripleInteractor(), DoubleInteractor()))
        let task = merge.sendViewEvent(3)
        // Final value is from last interactor (DoubleInteractor)
        #expect(merge.value == 6)
        // Both interactors' effects started, in merge order
        #expect(task != nil)
        #expect(merge.effectLog == ["triple", "double"])
    }

    private func makeViewModel<I: Interactor<ArithmeticState, Int>>(
        _ interactor: I
    ) -> ViewModel<Feature<Int, ArithmeticState>> {
        ViewModel(initialState: ArithmeticState(), feature: Feature(interactor: interactor))
    }
}
