import CasePaths
import Clocks
import Foundation
import Testing

@testable import Lattice

// MARK: - Child

@FeatureState
struct LoaderState: Equatable {
    var probes: [Bool] = []
    var downloadProbes: [Bool] = []
    var mixedRuns = 0
}

@CasePathable
enum LoaderAction: Equatable {
    case load
    case reload
    case cancel
    case probe
    case cancelThenProbe
    case loadThenCancel
    case cancelThenLoad
    case cancelFromEffect
    case finishInPreamble
    case mixed
    case download(Int)
    case cancelDownload(Int)
    case probeDownload(Int)
}

@Interactor<LoaderState, LoaderAction>
struct LoaderInteractor {
    @EffectID var load
    @EffectID var download
    let name: String
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .load:
                effects.perform(id: load) {
                    log.append("\(name) load started isRunning=\(effects.isRunning(load))")
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "\(name) load cancelled")
                }

            case .reload:
                effects.perform(id: load) {
                    log.append("\(name) reload started")
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "\(name) reload cancelled")
                }

            case .cancel:
                effects.cancel(load)

            case .probe:
                state.probes.append(effects.isRunning(load))

            case .cancelThenProbe:
                effects.cancel(load)
                state.probes.append(effects.isRunning(load))

            case .loadThenCancel:
                effects.perform(id: load) {
                    log.append("\(name) short load started")
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "\(name) short load cancelled")
                }
                effects.cancel(load)

            case .cancelThenLoad:
                effects.cancel(load)
                effects.perform(id: load) {
                    log.append("\(name) replacement load started isRunning=\(effects.isRunning(load))")
                    try await log.sleepUntilCancelled(
                        on: clock,
                        appendingOnCancel: "\(name) replacement load cancelled"
                    )
                }

            case .cancelFromEffect:
                effects.perform {
                    effects.cancel(load)
                    log.append("cancel returned isRunning=\(effects.isRunning(load))")
                }

            case .finishInPreamble:
                effects.perform(id: load) {
                    log.append("\(name) load finished in its preamble")
                }

            case .mixed:
                state.mixedRuns += 1
                let run = state.mixedRuns
                if run == 1 {
                    effects.perform(id: load) {
                        try await log.sleepUntilCancelled(
                            on: clock,
                            appendingOnCancel: "\(name) identified effect cancelled"
                        )
                    }
                }
                effects.perform {
                    try await log.sleepUntilCancelled(
                        on: clock,
                        appendingOnCancel: "\(name) anonymous effect #\(run) cancelled"
                    )
                }

            case .download(let row):
                effects.perform(id: $download.scoped(row)) {
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "\(name) download \(row) cancelled")
                }

            case .cancelDownload(let row):
                effects.cancel($download.scoped(row))

            case .probeDownload(let row):
                state.downloadProbes.append(effects.isRunning($download.scoped(row)))
            }
        }
    }
}

/// One `@EffectID` declaration in a generic interactor: every specialization shares its key.
struct GenericLoader<Tag>: Interactor {
    typealias State = LoaderState
    typealias Action = LoaderAction

    @EffectID var work
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            if case .load = action {
                effects.perform(id: work) {
                    log.append("\(Tag.self) started")
                    try await log.sleepUntilCancelled(on: clock, appendingOnCancel: "\(Tag.self) cancelled")
                }
            }
        }
    }
}

// MARK: - Parent

@FeatureState
struct LoaderParentState: Equatable {
    var a = LoaderState()
    var b = LoaderState()
    var pair = LoaderState()
}

@CasePathable
enum LoaderParentAction: Equatable {
    case a(LoaderAction)
    case b(LoaderAction)
    case pair(LoaderAction)
}

/// Every child is built inside `body`, so each `interact` routes to new child instances.
@Interactor<LoaderParentState, LoaderParentAction>
struct LoaderParentInteractor {
    let log: EffectLog
    let clock: TestClock<Duration>

    var body: some InteractorOf<Self> {
        // The same child type under two `When`s: separate scopes.
        Interactors.When(state: \.a, action: \.a) {
            LoaderInteractor(name: "a", log: log, clock: clock)
        }
        Interactors.When(state: \.b, action: \.b) {
            LoaderInteractor(name: "b", log: log, clock: clock)
        }
        // Two instances of the child type in one scope: one key.
        Interactors.When(state: \.pair, action: \.pair) {
            LoaderInteractor(name: "first", log: log, clock: clock)
            LoaderInteractor(name: "second", log: log, clock: clock)
        }
    }
}

/// Builds a loader at a call site of its own (another line, another function).
private func makeLoaderElsewhere(log: EffectLog, clock: TestClock<Duration>) -> LoaderInteractor {
    LoaderInteractor(name: "elsewhere", log: log, clock: clock)
}

// MARK: - Tests

/// Effects performed with an `@EffectID` key: replaced per key, never auto-cancelled, cancelled and
/// queried explicitly, and scoped by the `When` chain of the handle.
@MainActor
@Suite
struct EffectIDTests {
    private func makeViewModel(log: EffectLog) -> ViewModel<Feature<LoaderParentAction, LoaderParentState>> {
        ViewModel(
            initialState: LoaderParentState(),
            feature: Feature(interactor: LoaderParentInteractor(log: log, clock: TestClock()))
        )
    }

    @Test
    func keyIsTheDeclarationSiteAcrossInstancesAndGenericSpecializations() {
        let log = EffectLog()
        let clock = TestClock()
        let first = LoaderInteractor(name: "first", log: log, clock: clock)
        let second = LoaderInteractor(
            name: "second",
            log: log,
            clock: clock
        )
        let elsewhere = makeLoaderElsewhere(log: log, clock: clock)

        // Built at three call sites, equal keys: the key comes from the declaration.
        #expect(first.load == second.load)
        #expect(first.load == elsewhere.load)
        #expect(first.download == second.download)
        // Two declarations, two keys.
        #expect(first.load != first.download)
        // One declaration in a generic type, one key for every specialization.
        #expect(GenericLoader<Int>(log: log, clock: clock).work == GenericLoader<String>(log: log, clock: clock).work)
        // Per-element keys of one declaration.
        #expect(first.$download.scoped(1) == second.$download.scoped(1))
        #expect(first.$download.scoped(1) != first.$download.scoped(2))
        #expect(first.$download.scoped(1) != first.download)
    }

    @Test
    func effectIsCancelledFromAnotherCaseAlthoughEachInteractRebuildsTheChild() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.load))
        viewModel.sendViewEvent(.a(.cancel))

        #expect(log.entries == ["a load started isRunning=true", "a load cancelled"])
        viewModel.sendViewEvent(.a(.probe))
        #expect(viewModel.a.probes == [false])
    }

    @Test
    func effectIsReplacedPerKeyFromAnyCase() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.load))
        viewModel.sendViewEvent(.a(.reload))

        // The previous effect of the key is cancelled before the new one starts.
        #expect(log.entries == ["a load started isRunning=true", "a load cancelled", "a reload started"])
        viewModel.sendViewEvent(.a(.probe))
        #expect(viewModel.a.probes == [true])
    }

    @Test
    func effectIsNotAutoCancelledWhenItsCaseIsHandledAgain() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.mixed))  // performs an identified and an anonymous effect
        viewModel.sendViewEvent(.a(.mixed))  // performs only an anonymous effect

        #expect(log.entries == ["a anonymous effect #1 cancelled"])
        viewModel.sendViewEvent(.a(.probe))
        #expect(viewModel.a.probes == [true])
    }

    @Test
    func cancelQueuedDuringInteractRunsInOrderAfterTheEffectPerformedBeforeIt() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.loadThenCancel))

        // The effect performed first started (its preamble ran), then the queued cancel ran.
        #expect(log.entries == ["a short load started", "a short load cancelled"])
        viewModel.sendViewEvent(.a(.probe))
        #expect(viewModel.a.probes == [false])
    }

    @Test
    func cancelQueuedDuringInteractRunsInOrderBeforeTheEffectPerformedAfterIt() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.load))
        viewModel.sendViewEvent(.a(.cancelThenLoad))

        // The queued cancel ran first and cancelled only the running effect; the effect performed
        // after it started and keeps running.
        #expect(
            log.entries == [
                "a load started isRunning=true",
                "a load cancelled",
                "a replacement load started isRunning=true",
            ]
        )
        viewModel.sendViewEvent(.a(.probe))
        #expect(viewModel.a.probes == [true])
    }

    @Test
    func cancelFromAnEffectIsImmediate() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.load))
        viewModel.sendViewEvent(.a(.cancelFromEffect))

        #expect(
            log.entries == [
                "a load started isRunning=true",
                "a load cancelled",
                "cancel returned isRunning=false",
            ]
        )
    }

    @Test
    func isRunningFromInteractAndFromTheEffectsOwnPreamble() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.probe))
        viewModel.sendViewEvent(.a(.load))
        viewModel.sendViewEvent(.a(.probe))

        #expect(log.entries == ["a load started isRunning=true"])
        #expect(viewModel.a.probes == [false, true])
    }

    /// Current behaviour: the task `send` returns cancels its effects from its own cancellation
    /// handler, off the model's isolation, so the runtime learns of it only when the effect ends.
    @Test
    func isRunningStaysTrueAfterTheSendTaskIsCancelledUntilTheEffectUnwinds() async throws {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        let task = viewModel.sendViewEvent(.a(.load))
        task?.cancel()
        if #available(iOS 26, macOS 26, watchOS 26, *) {
            // The send task started immediately (`Task.immediate`), so its cancellation handler has
            // already cancelled the effect. Earlier OS versions start it later, as a plain `Task`.
            // Checked before the wait, so a cancel that did not arrive fails instead of hanging.
            try #require(log.entries == ["a load started isRunning=true", "a load cancelled"])
        }
        viewModel.sendViewEvent(.a(.probe))

        await task?.value
        viewModel.sendViewEvent(.a(.probe))

        #expect(viewModel.a.probes == [true, false])
    }

    @Test
    func cancelThenIsRunningInOneInteractIsTrueUntilTheNextAction() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.load))
        viewModel.sendViewEvent(.a(.cancelThenProbe))  // the cancel is queued behind the probe
        viewModel.sendViewEvent(.a(.probe))

        #expect(viewModel.a.probes == [true, false])
        #expect(log.entries == ["a load started isRunning=true", "a load cancelled"])
    }

    @Test
    func twoWhensOverTheSameChildKeepIndependentEffectsThroughTheirScopePaths() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.load))
        viewModel.sendViewEvent(.b(.load))
        viewModel.sendViewEvent(.a(.cancel))

        #expect(
            log.entries == [
                "a load started isRunning=true",
                "b load started isRunning=true",
                "a load cancelled",
            ]
        )
        viewModel.sendViewEvent(.a(.probe))
        viewModel.sendViewEvent(.b(.probe))
        #expect(viewModel.a.probes == [false])
        #expect(viewModel.b.probes == [true])
    }

    /// Without a scope path to tell them apart, two instances of one child type collide on their
    /// key: the second replaces the first.
    @Test
    func twoInstancesOfAChildInOneScopeShareItsKey() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.pair(.load))

        #expect(
            log.entries == [
                "first load started isRunning=true",
                "first load cancelled",
                "second load started isRunning=true",
            ]
        )
    }

    @Test
    func genericSpecializationsInOneScopeShareTheirKey() {
        let log = EffectLog()
        let clock = TestClock()
        let viewModel = ViewModel(
            initialState: LoaderState(),
            feature: Feature(
                interactor: Interactors.Merge(
                    GenericLoader<Int>(log: log, clock: clock),
                    GenericLoader<String>(log: log, clock: clock)
                )
            )
        )

        viewModel.sendViewEvent(.load)

        #expect(log.entries == ["Int started", "Int cancelled", "String started"])
    }

    @Test
    func perElementKeysFromScopedAreIndependent() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        viewModel.sendViewEvent(.a(.download(1)))
        viewModel.sendViewEvent(.a(.download(2)))
        viewModel.sendViewEvent(.a(.cancelDownload(1)))

        #expect(log.entries == ["a download 1 cancelled"])
        viewModel.sendViewEvent(.a(.probeDownload(1)))
        viewModel.sendViewEvent(.a(.probeDownload(2)))
        #expect(viewModel.a.downloadProbes == [false, true])
    }

    @Test
    func effectThatFinishesInItsPreambleIsNotRunning() {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        let task = viewModel.sendViewEvent(.a(.finishInPreamble))

        #expect(task != nil)
        #expect(log.entries == ["a load finished in its preamble"])
        viewModel.sendViewEvent(.a(.probe))
        #expect(viewModel.a.probes == [false])
    }
}
