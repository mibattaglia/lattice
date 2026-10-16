import Foundation
import Testing

@testable import Lattice

@FeatureState
struct TeardownState: Equatable {
    var count = 0
}

enum TeardownAction {
    case sleepThenSendAndModify
    case incrementReadThenSleepThenReadState
    case ping
}

/// Its effects sleep on a clock the tests never advance, so only teardown ends the sleep. What they
/// see after that, when they may no longer write state, goes to the log.
@Interactor<TeardownState, TeardownAction>
struct TeardownInteractor {
    let log: EffectLog
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .sleepThenSendAndModify:
                effects.perform {
                    try? await clock.sleep(for: .seconds(1_000))
                    do { try effects.send(.ping) } catch { log.append("send threw \(type(of: error))") }
                    do { try effects.modify { $0.count = -1 } } catch { log.append("modify threw \(type(of: error))") }
                }

            case .incrementReadThenSleepThenReadState:
                effects.perform {
                    try effects.modify { $0.count += 1 }
                    _ = effects.state  // a successful read refreshes the last known value
                    try? await clock.sleep(for: .seconds(1_000))
                    log.append("effects.state.count=\(effects.state.count)")
                }

            case .ping:
                break
            }
        }
    }
}

/// `ViewModel` is the subject: what its deinit does to the effects it started, and what a handle that
/// outlived it does. Released on the main actor, the deinit runs inline, so the effects are cancelled
/// when the release returns; a cancelled sleep leaves the clock inside the `cancel()` call.
@MainActor
@Suite
struct ViewModelTeardownTests {
    @Test(.timeLimit(.minutes(1)))
    func deinitCancelsEffectsAndTheirLaterSendAndModifyThrowWithoutAnIssue() async throws {
        let log = EffectLog()
        let clock = EffectClock()
        weak var weakViewModel: ViewModel<Feature<TeardownAction, TeardownState>>?
        var task: Task<Void, Never>?
        do {
            let viewModel = ViewModel(
                initialState: TeardownState(),
                feature: Feature(interactor: TeardownInteractor(log: log, clock: clock))
            )
            weakViewModel = viewModel
            task = viewModel.sendViewEvent(.sleepThenSendAndModify)
            #expect(clock.sleeperCount == 1)
        }
        #expect(weakViewModel == nil)
        try #require(clock.sleeperCount == 0)  // cancelled by the deinit, synchronously

        await task?.value

        #expect(log.entries == ["send threw CancellationError", "modify threw CancellationError"])
    }

    /// Effect tasks hold the runtime weakly, so it ends with its view model: a read after that is
    /// reported and returns the last value the effect read.
    @Test(.timeLimit(.minutes(1)))
    func effectsStateAfterDeinitIsReportedAndReturnsTheLastKnownValue() async {
        let log = EffectLog()
        let clock = EffectClock()
        let issues = await reportedIssues {
            var task: Task<Void, Never>?
            do {
                let viewModel = ViewModel(
                    initialState: TeardownState(count: 7),
                    feature: Feature(interactor: TeardownInteractor(log: log, clock: clock))
                )
                task = viewModel.sendViewEvent(.incrementReadThenSleepThenReadState)
            }
            guard clock.sleeperCount == 0 else { return }  // not cancelled: do not wait forever
            await task?.value
        }

        #expect(issues == ["Read 'effects.state' after the model was invalidated or the scoped state went away"])
        // 8, not the initial 7: the value of the effect's last successful read.
        #expect(log.entries == ["effects.state.count=8"])
    }

    /// The caller is not a cancelled effect, so the late calls are reported as well as thrown. The
    /// fixtures are `ModificationTests`'.
    @Test
    func modifyAndSendThroughAHandleThatOutlivedItsViewModelThrowAndAreReported() async throws {
        let escaped = EscapedEffects()
        do {
            let viewModel = ViewModel(
                initialState: ModificationState(),
                feature: Feature(interactor: ModificationInteractor(escaped: escaped))
            )
            viewModel.sendViewEvent(.escapeHandle)
        }
        let effects = try #require(escaped.effects)

        let issues = await reportedIssueDetails {
            #expect(throws: CancellationError.self) { try effects.modify { $0.count = 1 } }
            #expect(throws: CancellationError.self) { try effects.send(.increment) }
        }

        #expect(
            issues.map(\.message) == [
                "Effect modified state after the model was invalidated",
                "Effect sent increment after the model was invalidated",
            ]
        )
    }
}
