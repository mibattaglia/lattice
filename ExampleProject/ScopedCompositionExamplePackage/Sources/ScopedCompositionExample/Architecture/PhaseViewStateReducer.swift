import Lattice

@ViewStateReducer<PhaseDomainState, PhaseViewState>
struct PhaseViewStateReducer {
    func initialViewState(for domainState: PhaseDomainState) -> PhaseViewState {
        .loading
    }

    var body: some ViewStateReducerOf<Self> {
        // The two-regimes discipline, applied at both enum levels: mutate payloads in place
        // while staying in a case (fine-grained; the enclosing identities are untouched and
        // no switch re-renders), and rebuild a case wholesale only on a real transition
        // (coarse; exactly that switch re-renders). Payloadless cases (.loading, .idle) are
        // reassigned every reduce; their _$inert-stable ids make those assignments
        // identity-equal no-ops.
        Self.buildViewState { domainState, viewState in
            guard domainState.isLoaded else {
                viewState = .loading
                return
            }
            guard viewState.is(\.success) else {
                viewState = .success(
                    SuccessViewState(
                        title: domainState.title,
                        summary: SummaryViewState(count: domainState.count),
                        session: SessionViewState(
                            name: domainState.sessionName,
                            telemetry: TelemetryViewState(
                                status: domainState.status,
                                subphase: .idle
                            )
                        )
                    )
                )
                return
            }
            viewState.modify(\.success) { success in
                success.title = domainState.title
                success.summary.count = domainState.count
                success.session.name = domainState.sessionName
                success.session.telemetry.status = domainState.status
                if !domainState.isActive {
                    success.session.telemetry.subphase = .idle
                } else if success.session.telemetry.subphase.is(\.active) {
                    success.session.telemetry.subphase.modify(\.active) {
                        $0.tick = domainState.tick
                        $0.note = domainState.note
                    }
                } else {
                    success.session.telemetry.subphase = .active(
                        ActiveViewState(tick: domainState.tick, note: domainState.note)
                    )
                }
            }
        }
    }
}
