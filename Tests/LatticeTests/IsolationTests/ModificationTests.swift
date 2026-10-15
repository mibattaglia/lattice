import CasePaths
import Foundation
import Testing

@testable import Lattice

// MARK: - Root feature

@FeatureState
struct ModificationChildState: Equatable {
    var value = 0
}

@CasePathable
enum ModificationChildAction: Equatable {
    case bumpAfterYield
}

@FeatureState
struct ModificationState: Equatable {
    var count = 0
    var title = "t"
    var note = "n"
    var child = ModificationChildState()
}

@CasePathable
enum ModificationAction: Equatable {
    case modifyDuringInteract
    case modifyInsideModify
    case sendInsideModify
    case performInsideModify
    case modifyThreeMembers
    case modifyCountAndTitleAfterYield
    case replaceWithEqualContentAfterYield
    case modifyInPreamble
    case modifyAndSendAfterGate
    case escapeHandle
    case child(ModificationChildAction)
    case increment
}

/// A handle an interactor let escape from `interact`.
final class EscapedEffects {
    var effects: Effects<ModificationState, ModificationAction>?
}

@Interactor<ModificationChildState, ModificationChildAction>
struct ModificationChildInteractor {
    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .bumpAfterYield:
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.value += 1 }
                }
            }
        }
    }
}

@Interactor<ModificationState, ModificationAction>
struct ModificationInteractor {
    let log: EffectLog
    let gate: EffectGate
    let escaped: EscapedEffects

    var body: some InteractorOf<Self> {
        Interactors.When(state: \.child, action: \.child) {
            ModificationChildInteractor()
        }
        Interact { state, action, effects in
            switch action {
            case .modifyDuringInteract:
                try? effects.modify { committed in
                    log.append("modify body ran")
                    committed.count = 99
                }
                state.count += 1

            case .modifyInsideModify:
                effects.perform {
                    try effects.modify { outer in
                        outer.count += 1
                        try? effects.modify { inner in inner.count += 100 }
                    }
                }

            case .sendInsideModify:
                effects.perform {
                    try effects.modify { state in
                        state.count += 1
                        let task = try? effects.send(.increment)
                        log.append(task == nil ? "nested send returned nil" : "nested send returned a task")
                    }
                }

            case .performInsideModify:
                effects.perform {
                    try effects.modify { state in
                        state.count += 1
                        effects.perform { log.append("nested effect ran") }
                    }
                }

            case .modifyThreeMembers:
                effects.perform {
                    try effects.modify { state in
                        state.count += 1
                        state.title = "title"
                        state.note = "note"
                    }
                }

            case .modifyCountAndTitleAfterYield:
                effects.perform {
                    await Task.yield()
                    try effects.modify { state in
                        state.count += 1
                        state.title = "title"
                    }
                }

            case .replaceWithEqualContentAfterYield:
                effects.perform {
                    await Task.yield()
                    try effects.modify { state in
                        state = ModificationState(
                            count: state.count,
                            title: state.title,
                            note: state.note,
                            child: ModificationChildState(value: state.child.value)
                        )
                    }
                }

            case .modifyInPreamble:
                state.title = "interact"
                effects.perform { try effects.modify { $0.count = 10 } }

            case .modifyAndSendAfterGate:
                effects.perform {
                    await gate.wait()
                    do { try effects.modify { $0.count += 1 } } catch { log.append("modify threw \(type(of: error))") }
                    do { try effects.send(.increment) } catch { log.append("send threw \(type(of: error))") }
                }

            case .escapeHandle:
                escaped.effects = effects

            case .child:
                break

            case .increment:
                state.count += 1
            }
        }
    }
}

/// Performs an effect through a handle outside `interact`. Synchronous, because `perform` is
/// unavailable from asynchronous contexts such as the test body.
private func performThroughEscapedHandle(_ effects: Effects<ModificationState, ModificationAction>, log: EffectLog) {
    effects.perform { log.append("escaped effect ran") }
}

/// Every commit `Core.didCommit` reported: the action (`nil` for a modification) and the state.
private final class CommitLog {
    var actions: [String?] = []
    var states: [ModificationState] = []
}

// MARK: - Case-scoped child

@FeatureState
struct GatedChildState: Equatable {
    var value = 0
}

@CasePathable
enum GatedChildAction: Equatable {
    case modifyBeforeAndAfterGate
    case readAfterGate
    case bumpAfterYield
}

@CasePathable
enum GatedModeAction: Equatable {
    case active(GatedChildAction)
    case deactivate
}

@Interactor<GatedChildState, GatedChildAction>
struct GatedChildInteractor {
    let log: EffectLog
    let gate: EffectGate

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .modifyBeforeAndAfterGate:
                effects.perform {
                    try effects.modify { $0.value += 1 }  // live: written back through the case path
                    await gate.wait()
                    try effects.modify { $0.value += 100 }  // stale: reported and dropped
                    let task = try effects.send(.bumpAfterYield)  // stale: reported, nil
                    log.append(task == nil ? "stale send returned nil" : "stale send returned a task")
                }

            case .readAfterGate:
                effects.perform {
                    await gate.wait()
                    log.append("stale read value=\(effects.state.value)")  // the first read
                }

            case .bumpAfterYield:
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.value += 1 }
                }
            }
        }
    }
}

@Interactor<GatedModeState, GatedModeAction>
struct GatedModeInteractor {
    let log: EffectLog
    let gate: EffectGate

    var body: some InteractorOf<Self> {
        Interact { state, action, _ in
            switch action {
            case .deactivate:
                state = .inactive
            case .active(.readAfterGate) where state == .inactive:
                // Enters the case in the same `interact` that routes the child action into it.
                state = .active(GatedChildState(value: 7))
            case .active:
                break
            }
        }
        Interactors.When(state: \.active, action: \.active) {
            GatedChildInteractor(log: log, gate: gate)
        }
    }
}

// MARK: - Tests

@MainActor
@Suite
struct ModificationTests {
    private func makeViewModel(
        log: EffectLog = EffectLog(),
        gate: EffectGate = EffectGate(),
        escaped: EscapedEffects = EscapedEffects(),
        areStatesEqual: ((ModificationState, ModificationState) -> Bool)? = { $0 == $1 }
    ) -> ViewModel<Feature<ModificationAction, ModificationState>> {
        ViewModel(
            initialState: ModificationState(),
            feature: Feature(
                interactor: ModificationInteractor(log: log, gate: gate, escaped: escaped),
                areStatesEqual: areStatesEqual
            )
        )
    }

    private func makeModeViewModel(
        _ initialState: GatedModeState,
        log: EffectLog,
        gate: EffectGate
    ) -> ViewModel<Feature<GatedModeAction, GatedModeState>> {
        ViewModel(initialState: initialState, feature: Feature(interactor: GatedModeInteractor(log: log, gate: gate)))
    }

    // MARK: Guards

    @Test
    func modifyDuringInteractIsReportedAndItsBodyDoesNotRun() async {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        let issues = await reportedIssues {
            viewModel.sendViewEvent(.modifyDuringInteract)
        }

        #expect(issues == ["Can't modify state from effects during interact; mutate the 'state' argument instead"])
        #expect(log.entries.isEmpty)
        #expect(viewModel.count == 1)
    }

    @Test
    func modifyInsideAModifyBodyIsReportedAndDropped() async {
        let viewModel = makeViewModel()

        let issues = await reportedIssues {
            await viewModel.sendViewEvent(.modifyInsideModify)?.value
        }

        #expect(issues == ["Can't modify state inside another 'modify'; dropped"])
        #expect(viewModel.count == 1)
    }

    @Test
    func sendInsideAModifyBodyIsReportedAndDropped() async {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        let issues = await reportedIssues {
            await viewModel.sendViewEvent(.sendInsideModify)?.value
        }

        #expect(issues == ["Can't send increment inside 'modify'; dropped"])
        #expect(log.entries == ["nested send returned nil"])
        #expect(viewModel.count == 1)
    }

    @Test
    func performInsideAModifyBodyIsReportedAndDropped() async {
        let log = EffectLog()
        let viewModel = makeViewModel(log: log)

        let issues = await reportedIssues {
            await viewModel.sendViewEvent(.performInsideModify)?.value
        }

        #expect(issues == ["Can't perform an effect inside 'modify'; dropped"])
        #expect(log.entries.isEmpty)
        #expect(viewModel.count == 1)
    }

    @Test
    func modifyAndSendAfterInvalidationThrowCancellationErrorWithoutAnIssue() async {
        let log = EffectLog()
        let gate = EffectGate()
        let core = Core(
            isolation: MainActor.shared,
            initialState: ModificationState(),
            interactor: ModificationInteractor(log: log, gate: gate, escaped: EscapedEffects()).eraseToAnyInteractor(),
            areStatesEqual: { $0 == $1 }
        )

        let task = core.send(.modifyAndSendAfterGate)
        core.invalidate()  // cancels the effect, which waits on a gate that ignores cancellation
        gate.open()
        await task?.value

        #expect(log.entries == ["modify threw CancellationError", "send threw CancellationError"])
        #expect(core.committedState.count == 0)

        let issues = await reportedIssues {
            #expect(core.send(.increment) == nil)
        }
        #expect(issues == ["Can't send increment to an invalidated model"])
    }

    @Test
    func modifyAndSendThroughAHandleThatOutlivedItsViewModelThrowAndAreReported() async throws {
        let log = EffectLog()
        let escaped = EscapedEffects()
        do {
            let viewModel = makeViewModel(escaped: escaped)
            viewModel.sendViewEvent(.escapeHandle)
        }
        let effects = try #require(escaped.effects)

        // The caller is not a cancelled effect, so the late calls are reported as well as thrown.
        let issues = await reportedIssues {
            do { try effects.modify { $0.count = 1 } } catch { log.append("modify threw \(type(of: error))") }
            do { try effects.send(.increment) } catch { log.append("send threw \(type(of: error))") }
        }

        #expect(
            issues == [
                "Effect modified state after the model was invalidated",
                "Effect sent increment after the model was invalidated",
            ]
        )
        #expect(log.entries == ["modify threw CancellationError", "send threw CancellationError"])
    }

    @Test
    func performOutsideInteractFromASynchronousEscapeIsReportedAndDropped() async throws {
        let log = EffectLog()
        let escaped = EscapedEffects()
        let viewModel = makeViewModel(log: log, escaped: escaped)
        viewModel.sendViewEvent(.escapeHandle)
        let effects = try #require(escaped.effects)

        let issues = await reportedIssues {
            performThroughEscapedHandle(effects, log: log)
        }

        #expect(issues == ["'effects.perform' must be called during interact; dropped"])
        // Dropped, not queued: the next send does not start it either.
        #expect(viewModel.sendViewEvent(.increment) == nil)
        #expect(log.entries.isEmpty)
    }

    // MARK: Commit and observation

    @Test
    func modifyIsOneCommitHoweverManyMembersItChanges() {
        let commits = CommitLog()
        let core = Core(
            isolation: MainActor.shared,
            initialState: ModificationState(),
            interactor: ModificationInteractor(log: EffectLog(), gate: EffectGate(), escaped: EscapedEffects())
                .eraseToAnyInteractor(),
            areStatesEqual: { $0 == $1 }
        )
        core.didCommit = { action, state in
            commits.actions.append(action.map { "\($0)" })
            commits.states.append(state)
        }

        core.send(.modifyThreeMembers)

        // The root transition, then one modification for all three members.
        #expect(commits.actions == ["modifyThreeMembers", nil])
        #expect(commits.states.last == ModificationState(count: 1, title: "title", note: "note"))
    }

    @Test
    func modifyNotifiesOnlyTheObserversOfTheMembersItChanges() async {
        let viewModel = makeViewModel()

        let task = viewModel.sendViewEvent(.modifyCountAndTitleAfterYield)
        let count = ObservationProbe { _ = viewModel.count }
        let title = ObservationProbe { _ = viewModel.title }
        let note = ObservationProbe { _ = viewModel.note }
        let childValue = ObservationProbe { _ = viewModel.child.value }
        let root = ObservationProbe { _ = viewModel.viewState }
        await task?.value

        #expect(count.didFire)
        #expect(title.didFire)
        #expect(!note.didFire)
        #expect(!childValue.didFire)
        #expect(!root.didFire)
        #expect(viewModel.count == 1)
        #expect(viewModel.title == "title")
    }

    @Test
    func contentEqualReplacementInModifyNotifiesNothing() async {
        let viewModel = makeViewModel()
        let rootID = viewModel.state._$id

        let task = viewModel.sendViewEvent(.replaceWithEqualContentAfterYield)
        let root = ObservationProbe { _ = viewModel.viewState }
        let count = ObservationProbe { _ = viewModel.count }
        let childValue = ObservationProbe { _ = viewModel.child.value }
        await task?.value

        #expect(!root.didFire)
        #expect(!count.didFire)
        #expect(!childValue.didFire)
        #expect(viewModel.state._$id == rootID)
    }

    /// Control for the test above: the same replacement goes through the commit's state-equality gate.
    @Test
    func contentEqualReplacementInModifyNotifiesTheRootWithoutStateEquality() async {
        let viewModel = makeViewModel(areStatesEqual: nil)

        let task = viewModel.sendViewEvent(.replaceWithEqualContentAfterYield)
        let root = ObservationProbe { _ = viewModel.viewState }
        await task?.value

        #expect(root.didFire)
    }

    @Test
    func preambleModificationIsVisibleWhenSendViewEventReturns() {
        let viewModel = makeViewModel()

        viewModel.sendViewEvent(.modifyInPreamble)

        #expect(viewModel.title == "interact")
        #expect(viewModel.count == 10)
    }

    // MARK: Scoped children

    @Test
    func childModifyIsWrittenBackThroughAWhenKeyPath() async {
        let viewModel = makeViewModel()

        let task = viewModel.sendViewEvent(.child(.bumpAfterYield))
        let childValue = ObservationProbe { _ = viewModel.child.value }
        let count = ObservationProbe { _ = viewModel.count }
        let root = ObservationProbe { _ = viewModel.viewState }
        await task?.value

        #expect(viewModel.child.value == 1)
        #expect(childValue.didFire)
        #expect(!count.didFire)
        #expect(!root.didFire)
    }

    @Test
    func childModifyIsWrittenBackThroughAWhenCasePath() async {
        let viewModel = makeModeViewModel(.active(GatedChildState(value: 0)), log: EffectLog(), gate: EffectGate())
        let rootID = viewModel.state._$id

        let task = viewModel.sendViewEvent(.active(.bumpAfterYield))
        let root = ObservationProbe { _ = viewModel.viewState }
        #expect(viewModel.state == .active(GatedChildState(value: 0)))
        await task?.value

        #expect(viewModel.state == .active(GatedChildState(value: 1)))
        #expect(!root.didFire)
        #expect(viewModel.state._$id == rootID)
    }

    @Test
    func staleCaseScopedChildModifyAndSendAreReportedAndLeaveTheParentUntouched() async {
        let log = EffectLog()
        let gate = EffectGate()
        let viewModel = makeModeViewModel(.active(GatedChildState()), log: log, gate: gate)
        var stateAfterSend: GatedModeState?

        let issues = await reportedIssues {
            let task = viewModel.sendViewEvent(.active(.modifyBeforeAndAfterGate))
            stateAfterSend = viewModel.state
            viewModel.sendViewEvent(.deactivate)
            gate.open()
            await task?.value
        }

        #expect(
            issues == [
                "Child effect modified state after its state was removed from the parent; dropped",
                "Child effect sent bumpAfterYield after its state was removed from the parent; dropped",
            ]
        )
        #expect(stateAfterSend == .active(GatedChildState(value: 1)))
        #expect(viewModel.state == .inactive)
        #expect(log.entries == ["stale send returned nil"])
    }

    @Test
    func staleCaseScopedChildReadBeforeAnySuccessfulReadReturnsTheSeededValue() async {
        let log = EffectLog()
        let gate = EffectGate()
        let viewModel = makeModeViewModel(.active(GatedChildState(value: 5)), log: log, gate: gate)

        let issues = await reportedIssues {
            let task = viewModel.sendViewEvent(.active(.readAfterGate))
            viewModel.sendViewEvent(.deactivate)
            gate.open()
            await task?.value
        }

        #expect(issues == ["Read 'effects.state' after the model was invalidated or the scoped state went away"])
        #expect(log.entries == ["stale read value=5"])
    }

    /// The child handle is seeded with the child state `When` routed to, which is the working copy's:
    /// here the case was entered by the same `interact`, so the committed state never had it.
    @Test
    func staleCaseScopedChildReadReturnsTheWorkingValueItWasSeededWith() async {
        let log = EffectLog()
        let gate = EffectGate()
        let viewModel = makeModeViewModel(.inactive, log: log, gate: gate)

        let issues = await reportedIssues {
            let task = viewModel.sendViewEvent(.active(.readAfterGate))
            #expect(viewModel.state == .active(GatedChildState(value: 7)))
            viewModel.sendViewEvent(.deactivate)
            gate.open()
            await task?.value
        }

        #expect(issues == ["Read 'effects.state' after the model was invalidated or the scoped state went away"])
        #expect(log.entries == ["stale read value=7"])
    }
}
