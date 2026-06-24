import Lattice

@Interactor<FineGrainedDomainState, FineGrainedEvent>
struct FineGrainedInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .setTitle(let title):
                state.title = title
                return .none

            case .bumpCount:
                state.count += 1
                return .none

            case .togglePhase:
                state.phaseActive.toggle()
                return .none
            }
        }
    }
}
