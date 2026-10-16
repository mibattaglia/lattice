import Foundation
import Testing

@testable import Lattice

@Suite
struct MergeTests {
    /// Alone, `TripleInteractor` writes 9 and `DoubleInteractor` 6. `Merge` runs both in order, so
    /// the last one's value wins, and starts both effects, in merge order, before `send` returns.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func mergeRunsBothInteractorsAndTheirEffectsInOrder() async {
        let triple = await makeArithmeticModel(TripleInteractor())
        await triple.send(3) {
            $0.value = 9
            $0.performed = ["triple"]
        }
        await triple.finish()

        let double = await makeArithmeticModel(DoubleInteractor())
        await double.send(3) {
            $0.value = 6
            $0.performed = ["double"]
        }
        await double.finish()

        let merge = await makeArithmeticModel(Interactors.Merge(TripleInteractor(), DoubleInteractor()))
        let task = await merge.send(3) {
            $0.value = 6
            $0.performed = ["triple", "double"]
        }

        #expect(task != nil)
        await merge.finish()
    }
}
