import Lattice

@Interactor<FineGrainedState, FineGrainedEvent>
struct FineGrainedInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .setTitle(let title):
                state.title = title

            case .bumpCount:
                state.count += 1

            case .togglePhase:
                state.phaseActive.toggle()
            }
        }
    }
}
