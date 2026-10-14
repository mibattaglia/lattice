import CasePaths
import Lattice
import Observation
import Testing

@testable import ScopedCompositionExample

private final class ChangeProbe: @unchecked Sendable {
    var didChange = false
}

/// Observes the reads `PhaseExampleView` and its children perform, so each test checks which
/// render boundaries a change crosses.
@MainActor
@Suite
struct PhaseExampleTests {
    private func makeViewModel(
        areStatesEqual: ((PhaseState, PhaseState) -> Bool)? = { $0 == $1 }
    ) -> PhaseExampleViewModel {
        ViewModel(
            initialState: .loading,
            feature: Feature(interactor: PhaseInteractor(), areStatesEqual: areStatesEqual)
        )
    }

    private func observe(_ read: () -> Void) -> ChangeProbe {
        let probe = ChangeProbe()
        withObservationTracking(read) { probe.didChange = true }
        return probe
    }

    private func telemetryScope(
        of viewModel: PhaseExampleViewModel
    ) -> ScopedViewModel<TelemetryState, TelemetryAction> {
        viewModel.scope(state: \.success, action: \.success)
            .scope(state: \.session, action: \.session)
            .scope(state: \.telemetry, action: \.telemetry)
    }

    // Without state equality, the root switch still stays put: a case without a payload keeps the
    // same identity across commits, so a commit that leaves `.loading` showing is not a wholesale
    // replacement.
    @Test
    func tickWhileLoadingDoesNotInvalidateTheRootSwitch() {
        let viewModel = makeViewModel(areStatesEqual: nil)
        let rootSwitch = observe { _ = viewModel.viewState }

        viewModel.sendViewEvent(.tick)
        #expect(!rootSwitch.didChange)
        #expect(viewModel.viewState == .loading)
    }

    @Test
    func tickWhileIdleInvalidatesNeitherSwitch() {
        let viewModel = makeViewModel()
        viewModel.sendViewEvent(.loaded)
        let telemetry = telemetryScope(of: viewModel)
        let rootSwitch = observe { _ = viewModel.viewState }
        let innerSwitch = observe { _ = telemetry.subphase }

        viewModel.sendViewEvent(.tick)
        #expect(!rootSwitch.didChange)
        #expect(!innerSwitch.didChange)
    }

    @Test
    func payloadEditsWhileActiveInvalidateOnlyTheirLeaf() {
        let viewModel = makeViewModel()
        viewModel.sendViewEvent(.loaded)
        viewModel.sendViewEvent(.success(.session(.telemetry(.startTapped))))
        let success = viewModel.scope(state: \.success, action: \.success)
        let telemetry = telemetryScope(of: viewModel)
        let active = telemetry.scope(state: \.subphase, action: \.subphase)
            .scope(state: \.active, action: \.active)

        let rootSwitch = observe { _ = viewModel.viewState }
        let innerSwitch = observe { _ = telemetry.subphase }
        let summary = observe { _ = success.scope(state: \.summary, action: \.summary).count }
        let tick = observe { _ = active.tick }
        let note = observe { _ = active.note }

        viewModel.sendViewEvent(.tick)
        #expect(tick.didChange)
        #expect(!note.didChange)
        #expect(!innerSwitch.didChange)
        #expect(!summary.didChange)
        #expect(!rootSwitch.didChange)
        #expect(active.tick == 1)

        let noteAfterTick = observe { _ = active.note }
        let tickAfterTick = observe { _ = active.tick }
        active.sendViewEvent(.noteChanged("typed"))
        #expect(noteAfterTick.didChange)
        #expect(!tickAfterTick.didChange)
        #expect(active.note == "typed")
    }

    @Test
    func caseTransitionsInvalidateExactlyTheirSwitch() {
        let viewModel = makeViewModel()
        let rootSwitchBeforeLoad = observe { _ = viewModel.viewState }
        viewModel.sendViewEvent(.loaded)
        #expect(rootSwitchBeforeLoad.didChange)

        let telemetry = telemetryScope(of: viewModel)
        let rootSwitch = observe { _ = viewModel.viewState }
        let innerSwitch = observe { _ = telemetry.subphase }
        telemetry.sendViewEvent(.startTapped)
        #expect(innerSwitch.didChange)
        #expect(!rootSwitch.didChange)

        let rootSwitchBeforeReset = observe { _ = viewModel.viewState }
        viewModel.sendViewEvent(.resetTapped)
        #expect(rootSwitchBeforeReset.didChange)
        #expect(viewModel.viewState == .loading)
    }

    @Test
    func resetAndStopReturnToDefaultPayloadsAndLateSendsAreDropped() async {
        let model = TestViewModel(
            initialState: .loading,
            feature: Feature(interactor: PhaseInteractor())
        )

        await model.send(.loaded) { $0 = .success(SuccessState()) }
        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }
        await model.send(.tick) {
            $0.modify(\.success) {
                $0.session.telemetry.subphase = .active(ActiveState(tick: 1, note: ""))
            }
        }
        await model.send(.success(.session(.telemetry(.stopTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .idle }
        }
        await model.send(.success(.session(.telemetry(.subphase(.active(.noteChanged("late")))))))
        await model.send(.success(.session(.telemetry(.startTapped)))) {
            $0.modify(\.success) { $0.session.telemetry.subphase = .active(ActiveState()) }
        }

        await model.send(.success(.titleChanged("Renamed"))) {
            $0.modify(\.success) { $0.title = "Renamed" }
        }
        await model.send(.resetTapped) { $0 = .loading }
        await model.send(.success(.titleChanged("Late")))
        await model.send(.loaded) { $0 = .success(SuccessState()) }
    }
}
