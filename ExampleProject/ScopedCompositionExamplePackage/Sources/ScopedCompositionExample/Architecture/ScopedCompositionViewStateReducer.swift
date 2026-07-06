import Lattice

@ViewStateReducer<ScopedCompositionDomainState, ScopedCompositionViewState>
struct ScopedCompositionViewStateReducer {
    func initialViewState(
        for domainState: ScopedCompositionDomainState
    ) -> ScopedCompositionViewState {
        ScopedCompositionViewState(
            dashboard: DashboardState(
                header: HeaderState(
                    title: domainState.title,
                    badge: BadgeState(
                        label: domainState.badgeLabel,
                        count: domainState.badgeCount
                    )
                )
            ),
            footer: FooterState(status: domainState.footerStatus)
        )
    }

    var body: some ViewStateReducerOf<Self> {
        // Every slice is mutated in place so leaf changes stay fine-grained: an unrelated
        // reduce leaves the other slices' identities untouched and their observers
        // uninvalidated.
        Self.buildViewState { domainState, viewState in
            viewState.dashboard.header.title = domainState.title
            viewState.dashboard.header.badge.label = domainState.badgeLabel
            viewState.dashboard.header.badge.count = domainState.badgeCount
            viewState.footer.status = domainState.footerStatus
        }
    }
}
