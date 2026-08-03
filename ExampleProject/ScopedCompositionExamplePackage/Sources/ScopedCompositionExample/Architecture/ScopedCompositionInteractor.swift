import Lattice

@Interactor<ScopedCompositionState, ScopedCompositionEvent>
struct ScopedCompositionInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .dashboard(.header(.titleChanged(let title))):
                state.dashboard.header.title = title

            case .dashboard(.header(.badge(.labelChanged(let label)))):
                state.dashboard.header.badge.label = label

            case .dashboard(.header(.badge(.incremented))):
                state.dashboard.header.badge.count += 1

            case .setFooter(let status):
                state.footer.status = status
            }
        }
    }
}
