import Lattice
import Testing

@testable import ScopedCompositionExample

// The suite runs the feature under `TestModel`. A child view sends through its scope chain, which
// embeds its action into the root action, so a test sends that root action: the badge's Increment
// button sends `.dashboard(.header(.badge(.incremented)))`. `send` asserts the whole state, so each
// test also shows that the action left the other slices alone.

@Suite
struct ScopedCompositionExampleTests {
    @Test
    func incrementingTheBadgeChangesOnlyItsCount() async {
        let model = await makeModel()

        await model.send(.dashboard(.header(.badge(.incremented)))) {
            $0.dashboard.header.badge.count = 1
        }
        await model.finish()
    }

    /// The badge's Label field binds `label` and sends `labelChanged` for each edit.
    @Test
    func typingABadgeLabelChangesOnlyTheLabel() async {
        let model = await makeModel()

        await model.send(.dashboard(.header(.badge(.labelChanged("Typed"))))) {
            $0.dashboard.header.badge.label = "Typed"
        }
        await model.finish()
    }

    @Test
    func updatingTheFooterChangesOnlyItsStatus() async {
        let model = await makeModel()

        await model.send(.setFooter("Updated")) { $0.footer.status = "Updated" }
        await model.finish()
    }
}

private func makeModel() async -> TestModel<Feature<ScopedCompositionEvent, ScopedCompositionState>> {
    await TestModel(initialState: ScopedCompositionState(), feature: Feature(interactor: ScopedCompositionInteractor()))
}
