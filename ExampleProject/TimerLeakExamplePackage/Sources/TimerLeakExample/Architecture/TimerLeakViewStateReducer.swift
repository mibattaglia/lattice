import Lattice

@ViewStateReducer<TimerLeakDomainState, TimerLeakViewState>
struct TimerLeakViewStateReducer {
    func initialViewState(for domainState: TimerLeakDomainState) -> TimerLeakViewState {
        TimerLeakViewState(
            tickCount: domainState.tickCount,
            child: Self.makeChild(value: domainState.displayedValue)
        )
    }

    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState, viewState in
            viewState.tickCount = domainState.tickCount
            // Wholesale child rebuild on every tick (assignment, not field
            // mutation). This is the whole point of the demo. The child carries
            // `rowCount` nested @ObservableState rows, so one content-equal
            // assignment orphans that many registrars per frame.
            viewState.child = Self.makeChild(value: domainState.displayedValue)
        }
    }

    private static func makeChild(value: String) -> TimerChildViewState {
        TimerChildViewState(
            value: value,
            rows: (0..<TimerLeakConstants.rowCount).map { id in
                TimerRowViewState(id: id, value: value)
            }
        )
    }
}
