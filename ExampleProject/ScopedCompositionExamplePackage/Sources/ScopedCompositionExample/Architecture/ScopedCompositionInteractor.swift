import Lattice

@Interactor<ScopedCompositionState, ScopedCompositionEvent>
struct ScopedCompositionInteractor: Sendable {
    var body: some InteractorOf<Self> {
        // Every action mutates its leaf in place, so leaf changes stay fine-grained: the other
        // slices' identities stay untouched and their observers uninvalidated.
        Interact { state, event in
            switch event {
            case .dashboard(.header(.titleChanged(let title))):
                state.dashboard.header.title = title
                return .none

            case .dashboard(.header(.badge(.labelChanged(let label)))):
                state.dashboard.header.badge.label = label
                return .none

            case .dashboard(.header(.badge(.incremented))):
                state.dashboard.header.badge.count += 1
                return .none

            case .setFooter(let status):
                state.footer.status = status
                return .none
            }
        }
    }
}
