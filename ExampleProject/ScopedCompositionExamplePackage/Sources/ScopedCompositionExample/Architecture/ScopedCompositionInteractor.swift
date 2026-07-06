import Lattice

@Interactor<ScopedCompositionDomainState, ScopedCompositionEvent>
struct ScopedCompositionInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .dashboard(.header(.titleChanged(let title))):
                state.title = title
                return .none

            case .dashboard(.header(.badge(.labelChanged(let label)))):
                state.badgeLabel = label
                return .none

            case .dashboard(.header(.badge(.incremented))):
                state.badgeCount += 1
                return .none

            case .setFooter(let status):
                state.footerStatus = status
                return .none
            }
        }
    }
}
