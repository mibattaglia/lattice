import CasePaths
import Foundation
import Testing

@testable import Lattice

// Every fixture is declared at file scope, so the interactors and their effect literals are
// nonisolated, as `TestModel` requires. The sleeping effects sleep on an `EffectClock`, then record
// that they completed: a cancelled or replaced effect throws at its sleep and never completes, so
// after `advance`, `expect` shows which effects are still running. `isRunning` is recorded in state:
// by `.probe` during `interact`, and by the `load` effects in their own preambles.

private let effectDuration: Duration = .seconds(1)

// MARK: - Child

@FeatureState
struct LoaderState: Equatable {
    var probes: [Bool] = []
    var downloadProbes: [Bool] = []
    var mixedRuns = 0
    /// `isRunning` of its own key, as each effect of the `load` key saw it in its preamble.
    var runningAtStart: [Bool] = []
    /// The effects that completed, by name.
    var completed: Set<String> = []
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
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .load:
                effects.perform(id: load) {
                    let isRunning = effects.isRunning(load)
                    try effects.modify { $0.runningAtStart.append(isRunning) }
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.insert("\(name) load") }
                }

            case .reload:
                effects.perform(id: load) {
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.insert("\(name) reload") }
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
                    let isRunning = effects.isRunning(load)
                    try effects.modify { $0.runningAtStart.append(isRunning) }
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.insert("\(name) short load") }
                }
                effects.cancel(load)

            case .cancelThenLoad:
                effects.cancel(load)
                effects.perform(id: load) {
                    let isRunning = effects.isRunning(load)
                    try effects.modify { $0.runningAtStart.append(isRunning) }
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.insert("\(name) replacement load") }
                }

            case .cancelFromEffect:
                effects.perform {
                    effects.cancel(load)
                    let isRunning = effects.isRunning(load)
                    try effects.modify { $0.probes.append(isRunning) }
                }

            case .finishInPreamble:
                effects.perform(id: load) {
                    try effects.modify { $0.completed.insert("\(name) load finished in its preamble") }
                }

            case .mixed:
                state.mixedRuns += 1
                let run = state.mixedRuns
                if run == 1 {
                    effects.perform(id: load) {
                        try await clock.sleep(for: effectDuration)
                        try effects.modify { $0.completed.insert("\(name) identified effect") }
                    }
                }
                effects.perform {
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.insert("\(name) anonymous effect #\(run)") }
                }

            case .download(let row):
                effects.perform(id: $download.scoped(row)) {
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.insert("\(name) download \(row)") }
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
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            if case .load = action {
                effects.perform(id: work) {
                    let isRunning = effects.isRunning(work)
                    try effects.modify { $0.runningAtStart.append(isRunning) }
                    try await clock.sleep(for: effectDuration)
                    try effects.modify { $0.completed.insert("\(Tag.self)") }
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
    let clock: EffectClock

    var body: some InteractorOf<Self> {
        // The same child type under two `When`s: separate scopes.
        Interactors.When(state: \.a, action: \.a) {
            LoaderInteractor(name: "a", clock: clock)
        }
        Interactors.When(state: \.b, action: \.b) {
            LoaderInteractor(name: "b", clock: clock)
        }
        // Two instances of the child type in one scope: one key.
        Interactors.When(state: \.pair, action: \.pair) {
            LoaderInteractor(name: "first", clock: clock)
            LoaderInteractor(name: "second", clock: clock)
        }
    }
}

/// Builds a loader at a call site of its own (another line, another function).
private func makeLoaderElsewhere(clock: EffectClock) -> LoaderInteractor {
    LoaderInteractor(name: "elsewhere", clock: clock)
}

// MARK: - Tests

/// Effects performed with an `@EffectID` key: replaced per key, never auto-cancelled, cancelled and
/// queried explicitly, and scoped by the `When` chain of the handle.
@Suite
struct EffectIDTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeModel(
        clock: EffectClock,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestModel<Feature<LoaderParentAction, LoaderParentState>> {
        await TestModel(
            initialState: LoaderParentState(),
            feature: Feature(interactor: LoaderParentInteractor(clock: clock)),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    @Test
    func keyIsTheDeclarationSiteAcrossInstancesAndGenericSpecializations() {
        let clock = EffectClock()
        let first = LoaderInteractor(name: "first", clock: clock)
        let second = LoaderInteractor(
            name: "second",
            clock: clock
        )
        let elsewhere = makeLoaderElsewhere(clock: clock)

        // Built at three call sites, equal keys: the key comes from the declaration.
        #expect(first.load == second.load)
        #expect(first.load == elsewhere.load)
        #expect(first.download == second.download)
        // Two declarations, two keys.
        #expect(first.load != first.download)
        // One declaration in a generic type, one key for every specialization.
        #expect(GenericLoader<Int>(clock: clock).work == GenericLoader<String>(clock: clock).work)
        // Per-element keys of one declaration.
        #expect(first.$download.scoped(1) == second.$download.scoped(1))
        #expect(first.$download.scoped(1) != first.$download.scoped(2))
        #expect(first.$download.scoped(1) != first.download)
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func effectIsCancelledFromAnotherCaseAlthoughEachInteractRebuildsTheChild() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.load)) { $0.a.runningAtStart = [true] }
        await model.send(.a(.cancel))
        await model.send(.a(.probe)) { $0.a.probes = [false] }

        await model.advance(clock, by: effectDuration)  // the load never completes
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func effectIsReplacedPerKeyFromAnyCase() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.load)) { $0.a.runningAtStart = [true] }
        await model.send(.a(.reload))  // replaces the load: another case, the same key
        await model.send(.a(.probe)) { $0.a.probes = [true] }

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.a.completed = ["a reload"] }  // the load never completed
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func effectIsNotAutoCancelledWhenItsCaseIsHandledAgain() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.mixed)) { $0.a.mixedRuns = 1 }  // performs an identified and an anonymous effect
        await model.send(.a(.mixed)) { $0.a.mixedRuns = 2 }  // performs only an anonymous effect
        await model.send(.a(.probe)) { $0.a.probes = [true] }

        await model.advance(clock, by: effectDuration)
        await model.expect {  // auto-cancel took only the first anonymous effect
            $0.a.completed = ["a identified effect", "a anonymous effect #2"]
        }
        await model.finish()
    }

    /// The effect performed first started, then the queued cancel ran: its preamble saw it running,
    /// and it never completes.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func cancelQueuedDuringInteractRunsInOrderAfterTheEffectPerformedBeforeIt() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.loadThenCancel)) { $0.a.runningAtStart = [true] }
        await model.send(.a(.probe)) { $0.a.probes = [false] }

        await model.advance(clock, by: effectDuration)  // the short load never completes
        await model.finish()
    }

    /// The queued cancel ran first and cancelled only the running effect; the effect performed
    /// after it started, saw itself running and completes.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func cancelQueuedDuringInteractRunsInOrderBeforeTheEffectPerformedAfterIt() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.load)) { $0.a.runningAtStart = [true] }
        await model.send(.a(.cancelThenLoad)) { $0.a.runningAtStart = [true, true] }
        await model.send(.a(.probe)) { $0.a.probes = [true] }

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.a.completed = ["a replacement load"] }  // the first load never completed
        await model.finish()
    }

    /// The effect's `cancel` takes effect before it returns: `isRunning` right after it is `false`.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func cancelFromAnEffectIsImmediate() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.load)) { $0.a.runningAtStart = [true] }
        await model.send(.a(.cancelFromEffect)) { $0.a.probes = [false] }

        await model.advance(clock, by: effectDuration)  // the load never completes
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func isRunningFromInteractAndFromTheEffectsOwnPreamble() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.probe)) { $0.a.probes = [false] }
        await model.send(.a(.load)) { $0.a.runningAtStart = [true] }
        await model.send(.a(.probe)) { $0.a.probes = [false, true] }

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.a.completed = ["a load"] }
        await model.finish()
    }

    /// Current behaviour: the task `send` returns cancels its effects from its own cancellation
    /// handler, off the model's isolation, so the runtime learns of it only when the effect ends.
    /// `TestViewModel`: the test holds the main actor, where the effect runs, from the cancel to the
    /// probe, so the effect cannot unwind in between.
    @MainActor
    @Test
    func isRunningStaysTrueAfterTheSendTaskIsCancelledUntilTheEffectUnwinds() async throws {
        let clock = EffectClock()
        let model = TestViewModel(
            initialState: LoaderParentState(),
            feature: Feature(interactor: LoaderParentInteractor(clock: clock))
        )

        let task = model.send(.a(.load)) { $0.a.runningAtStart = [true] }
        task?.cancel()
        if #available(iOS 26, macOS 26, watchOS 26, *) {
            // The send task started immediately (`Task.immediate`), so its cancellation handler has
            // already cancelled the effect, whose sleep is gone. Earlier OS versions start it later,
            // as a plain `Task`. Checked before the wait, so a cancel that did not arrive fails
            // instead of hanging.
            try #require(clock.sleeperCount == 0)
        }
        model.send(.a(.probe)) { $0.a.probes = [true] }

        await task?.value
        model.send(.a(.probe)) { $0.a.probes = [true, false] }
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func cancelThenIsRunningInOneInteractIsTrueUntilTheNextAction() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.load)) { $0.a.runningAtStart = [true] }
        await model.send(.a(.cancelThenProbe)) { $0.a.probes = [true] }  // the cancel is queued behind the probe
        await model.send(.a(.probe)) { $0.a.probes = [true, false] }

        await model.advance(clock, by: effectDuration)  // the load never completes
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func twoWhensOverTheSameChildKeepIndependentEffectsThroughTheirScopePaths() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.load)) { $0.a.runningAtStart = [true] }
        await model.send(.b(.load)) { $0.b.runningAtStart = [true] }
        await model.send(.a(.cancel))
        await model.send(.a(.probe)) { $0.a.probes = [false] }
        await model.send(.b(.probe)) { $0.b.probes = [true] }

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.b.completed = ["b load"] }  // a's load never completed
        await model.finish()
    }

    /// Without a scope path to tell them apart, two instances of one child type collide on their
    /// key: the second replaces the first.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func twoInstancesOfAChildInOneScopeShareItsKey() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.pair(.load)) { $0.pair.runningAtStart = [true, true] }  // both started

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.pair.completed = ["second load"] }  // the first never completed
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func genericSpecializationsInOneScopeShareTheirKey() async {
        let clock = EffectClock()
        let model = await TestModel(
            initialState: LoaderState(),
            feature: Feature(
                interactor: Interactors.Merge(GenericLoader<Int>(clock: clock), GenericLoader<String>(clock: clock))
            )
        )

        await model.send(.load) { $0.runningAtStart = [true, true] }  // both started

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.completed = ["String"] }  // the `Int` loader's effect never completed
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func perElementKeysFromScopedAreIndependent() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.a(.download(1)))
        await model.send(.a(.download(2)))
        await model.send(.a(.cancelDownload(1)))
        await model.send(.a(.probeDownload(1))) { $0.a.downloadProbes = [false] }
        await model.send(.a(.probeDownload(2))) { $0.a.downloadProbes = [false, true] }

        await model.advance(clock, by: effectDuration)
        await model.expect { $0.a.completed = ["a download 2"] }  // download 1 never completed
        await model.finish()
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func effectThatFinishesInItsPreambleIsNotRunning() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        let task = await model.send(.a(.finishInPreamble)) {
            $0.a.completed = ["a load finished in its preamble"]
        }

        #expect(task != nil)
        await model.send(.a(.probe)) { $0.a.probes = [false] }
        await model.finish()
    }
}
