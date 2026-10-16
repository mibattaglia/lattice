import Lattice
import Testing

@testable import FineGrainedExample

// The suite runs the feature under `TestModel`. `send` asserts the whole state, so each test also
// shows that the action left the other members alone.

@Suite
struct FineGrainedExampleTests {
    @Test
    func bumpingTheCountChangesOnlyTheCount() async {
        let model = await makeModel()

        await model.send(.bumpCount) { $0.count = 1 }
        await model.finish()
    }

    @Test
    func changingTheTitleChangesOnlyTheTitle() async {
        let model = await makeModel()

        await model.send(.setTitle("Updated")) { $0.title = "Updated" }
        await model.finish()
    }

    /// Toggling the phase flips the hidden `phaseActive`; views read the `phase` derived from it.
    @Test
    func togglingThePhaseShowsTheActivePhase() async {
        let model = await makeModel()

        await model.send(.togglePhase) { $0.phaseActive = true }
        #expect(await model.state.phase == .active("Active!"))
        await model.finish()
    }
}

private func makeModel() async -> TestModel<Feature<FineGrainedEvent, FineGrainedState>> {
    await TestModel(initialState: FineGrainedState(), feature: Feature(interactor: FineGrainedInteractor()))
}
