import Lattice

@ViewStateReducer<FineGrainedDomainState, FineGrainedViewState>
struct FineGrainedViewStateReducer {
    func initialViewState(for domainState: FineGrainedDomainState) -> FineGrainedViewState {
        FineGrainedViewState(
            header: FineGrainedHeader(title: domainState.title),
            footer: FineGrainedFooter(count: domainState.count),
            phase: domainState.phaseActive ? .active("Active!") : .idle
        )
    }

    var body: some ViewStateReducerOf<Self> {
        // Each slice is mutated in place so an unrelated reduce leaves the other slices'
        // identities untouched and their observers uninvalidated.
        Self.buildViewState { domainState, viewState in
            viewState.header.title = domainState.title
            viewState.footer.count = domainState.count
            viewState.phase = domainState.phaseActive ? .active("Active!") : .idle
        }
    }
}
