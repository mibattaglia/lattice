import CasePaths
import Foundation
import Testing

@testable import Lattice

// The fixtures are declared at file scope, so the interactors and their effect literals are
// nonisolated, as `TestModel` requires; `ModificationObservationTests` and `ViewModelTeardownTests`
// drive the same fixtures through `ViewModel`. Results are recorded in state, and a fixture that runs
// where it must not records an issue or a modification the test would have to assert. Only what an
// effect sees after it may no longer write state (a stale case-scoped child, an invalidated model)
// goes to an `EffectLog`.

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
    var log = EffectLog()
    var gate = Gate()
    var escaped = EscapedEffects()

    var body: some InteractorOf<Self> {
        Interactors.When(state: \.child, action: \.child) {
            ModificationChildInteractor()
        }
        Interact { state, action, effects in
            switch action {
            case .modifyDuringInteract:
                try? effects.modify { committed in
                    Issue.record("The body of a 'modify' called during interact ran")
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
                        state.note = task == nil ? "nested send returned nil" : "nested send returned a task"
                    }
                }

            case .performInsideModify:
                effects.perform {
                    try effects.modify { state in
                        state.count += 1
                        effects.perform { try effects.modify { $0.title = "nested effect ran" } }
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
/// unavailable from asynchronous contexts such as the test body. The effect would write `title`.
private func performThroughEscapedHandle(_ effects: Effects<ModificationState, ModificationAction>) {
    effects.perform { try effects.modify { $0.title = "escaped effect ran" } }
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
    case bumpInPreamble
}

@CasePathable
enum GatedModeAction: Equatable {
    case active(GatedChildAction)
    case deactivate
}

/// `.modifyBeforeAndAfterGate` waits on `writeGate`, `.readAfterGate` on `readGate`, so a test opens
/// them one at a time. After its gate, an effect logs what its send returned and what it read: after a
/// deactivation, those are what a stale child sees, which it cannot write into state.
@Interactor<GatedChildState, GatedChildAction>
struct GatedChildInteractor {
    let log: EffectLog
    let writeGate: Gate
    let readGate: Gate

    var body: some InteractorOf<Self> {
        Interact { _, action, effects in
            switch action {
            case .modifyBeforeAndAfterGate:
                effects.perform {
                    try effects.modify { $0.value += 1 }  // live: written back through the case path
                    await writeGate.wait()
                    try effects.modify { $0.value += 100 }  // stale: reported and dropped
                    let task = try effects.send(.bumpInPreamble)  // stale: reported, nil
                    log.append(task == nil ? "send returned nil" : "send returned a task")
                }

            case .readAfterGate:
                effects.perform {
                    await readGate.wait()
                    log.append("read value=\(effects.state.value)")  // the first read
                }

            case .bumpAfterYield:
                effects.perform {
                    await Task.yield()
                    try effects.modify { $0.value += 1 }
                }

            case .bumpInPreamble:
                effects.perform { try effects.modify { $0.value += 1 } }
            }
        }
    }
}

@Interactor<GatedModeState, GatedModeAction>
struct GatedModeInteractor {
    var log = EffectLog()
    var writeGate = Gate()
    var readGate = Gate()

    var body: some InteractorOf<Self> {
        Interact { state, action in
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
            GatedChildInteractor(log: log, writeGate: writeGate, readGate: readGate)
        }
    }
}

// MARK: - Tests

/// `effects.modify`: its guards, one commit per call, the preamble's modification inside `send`, and
/// case-scoped children that went away. Which observations a modification fires is
/// `ModificationObservationTests`'.
@Suite
struct ModificationTests {
    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeModel(
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestModel<Feature<ModificationAction, ModificationState>> {
        await TestModel(
            initialState: ModificationState(),
            feature: Feature(interactor: ModificationInteractor()),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    private func makeModeModel(
        _ initialState: GatedModeState,
        log: EffectLog,
        writeGate: Gate = Gate(),
        readGate: Gate = Gate(),
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestModel<Feature<GatedModeAction, GatedModeState>> {
        await TestModel(
            initialState: initialState,
            feature: Feature(interactor: GatedModeInteractor(log: log, writeGate: writeGate, readGate: readGate)),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    // MARK: Guards

    /// The `modify` body records an issue if it runs, so the exact issue list also shows that it
    /// did not.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func modifyDuringInteractIsReportedAndItsBodyDoesNotRun() async {
        let issues = await reportedIssueDetails {
            let model = await makeModel()
            await model.send(.modifyDuringInteract) { $0.count = 1 }
            await model.finish()
        }

        #expect(
            issues.map(\.message) == [
                "Can't modify state from effects during interact; mutate the 'state' argument instead"
            ]
        )
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func modifyInsideAModifyBodyIsReportedAndDropped() async {
        let issues = await reportedIssueDetails {
            let model = await makeModel()
            await model.send(.modifyInsideModify) { $0.count = 1 }  // the outer modification only
            await model.finish()
        }

        #expect(issues.map(\.message) == ["Can't modify state inside another 'modify'; dropped"])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func sendInsideAModifyBodyIsReportedAndDropped() async {
        let issues = await reportedIssueDetails {
            let model = await makeModel()
            await model.send(.sendInsideModify) {  // and no `.increment`
                $0.count = 1
                $0.note = "nested send returned nil"
            }
            await model.finish()
        }

        #expect(issues.map(\.message) == ["Can't send increment inside 'modify'; dropped"])
    }

    /// The dropped effect would write `title`: `finish` would report that modification.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func performInsideAModifyBodyIsReportedAndDropped() async {
        let issues = await reportedIssueDetails {
            let model = await makeModel()
            await model.send(.performInsideModify) { $0.count = 1 }
            await model.finish()
        }

        #expect(issues.map(\.message) == ["Can't perform an effect inside 'modify'; dropped"])
    }

    /// A bare `Core`: the test invalidates it while the effect waits on a gate that ignores
    /// cancellation, which no shell lets a test do. The invalidated effect can no longer write
    /// state, so what its calls threw is logged.
    @MainActor
    @Test
    func modifyAndSendAfterInvalidationThrowCancellationErrorWithoutAnIssue() async {
        let log = EffectLog()
        let gate = Gate()
        let core = Core(
            isolation: MainActor.shared,
            initialState: ModificationState(),
            interactor: ModificationInteractor(log: log, gate: gate).eraseToAnyInteractor(),
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

    /// `TestViewModel`: the test calls the escaped, non-`Sendable` handle itself, on the main actor
    /// where the feature runs. The dropped effect would write `title`: `finish` would report that
    /// modification.
    @MainActor
    @Test
    func performOutsideInteractFromASynchronousEscapeIsReportedAndDropped() async {
        let escaped = EscapedEffects()
        let issues = await reportedIssueDetails {
            let model = TestViewModel(
                initialState: ModificationState(),
                feature: Feature(interactor: ModificationInteractor(escaped: escaped))
            )
            model.send(.escapeHandle)
            guard let effects = escaped.effects else {
                Issue.record("The interactor did not let its handle escape")
                return
            }

            performThroughEscapedHandle(effects)

            // Dropped, not queued: the next send does not start it either.
            let task = model.send(.increment) { $0.count = 1 }
            #expect(task == nil)
            await model.finish()
        }

        #expect(issues.map(\.message) == ["'effects.perform' must be called during interact; dropped"])
    }

    // MARK: Commit

    /// A bare `Core`: the commits are `Core.didCommit`'s, which the test shells fold.
    @MainActor
    @Test
    func modifyIsOneCommitHoweverManyMembersItChanges() {
        let commits = CommitLog()
        let core = Core(
            isolation: MainActor.shared,
            initialState: ModificationState(),
            interactor: ModificationInteractor().eraseToAnyInteractor(),
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

    /// The preamble's modification is committed before `send` returns, so `send` folds it in.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test
    func preambleModificationIsVisibleWhenSendReturns() async {
        let model = await makeModel()

        await model.send(.modifyInPreamble) {
            $0.title = "interact"
            $0.count = 10
        }
        await model.finish()
    }

    // MARK: Scoped children

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func staleCaseScopedChildModifyAndSendAreReportedAndLeaveTheParentUntouched() async {
        let log = EffectLog()
        let writeGate = Gate()
        let issues = await reportedIssueDetails {
            let model = await makeModeModel(.active(GatedChildState()), log: log, writeGate: writeGate)
            let task = await model.send(.active(.modifyBeforeAndAfterGate)) {
                $0.modify(\.active) { $0.value = 1 }  // the live modification, from the preamble
            }
            await model.send(.deactivate) { $0 = .inactive }
            writeGate.open()
            await task?.value
            await model.finish()  // the stale modification and send were dropped: nothing reached the parent
        }

        #expect(
            issues.map(\.message) == [
                "Child effect modified state after its state was removed from the parent; dropped",
                "Child effect sent bumpInPreamble after its state was removed from the parent; dropped",
            ]
        )
        #expect(log.entries == ["send returned nil"])
    }

    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func staleCaseScopedChildReadBeforeAnySuccessfulReadReturnsTheSeededValue() async {
        let log = EffectLog()
        let readGate = Gate()
        let issues = await reportedIssueDetails {
            let model = await makeModeModel(.active(GatedChildState(value: 5)), log: log, readGate: readGate)
            let task = await model.send(.active(.readAfterGate))
            await model.send(.deactivate) { $0 = .inactive }
            readGate.open()
            await task?.value
            await model.finish()
        }

        #expect(
            issues.map(\.message) == ["Read 'effects.state' after the model was invalidated or the scoped state went away"]
        )
        #expect(log.entries == ["read value=5"])
    }

    /// The child handle is seeded with the child state `When` routed to, which is the working copy's:
    /// here the case was entered by the same `interact`, so the committed state never had it.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func staleCaseScopedChildReadReturnsTheWorkingValueItWasSeededWith() async {
        let log = EffectLog()
        let readGate = Gate()
        let issues = await reportedIssueDetails {
            let model = await makeModeModel(.inactive, log: log, readGate: readGate)
            let task = await model.send(.active(.readAfterGate)) { $0 = .active(GatedChildState(value: 7)) }
            await model.send(.deactivate) { $0 = .inactive }
            readGate.open()
            await task?.value
            await model.finish()
        }

        #expect(
            issues.map(\.message) == ["Read 'effects.state' after the model was invalidated or the scoped state went away"]
        )
        #expect(log.entries == ["read value=7"])
    }

    /// A case-scoped child effect that outlives a deactivation writes and sends through the new
    /// payload once the case is active again, and a read goes through it too. The gates open one
    /// at a time, so the read comes after the write and the send.
    @available(iOS 26, macOS 26, watchOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func caseScopedChildEffectUsesTheNewPayloadAfterReactivation() async {
        let log = EffectLog()
        let writeGate = Gate()
        let readGate = Gate()
        let issues = await reportedIssueDetails {
            let model = await makeModeModel(
                .active(GatedChildState(value: 0)),
                log: log,
                writeGate: writeGate,
                readGate: readGate
            )
            let task = await model.send(.active(.modifyBeforeAndAfterGate)) {
                $0.modify(\.active) { $0.value = 1 }  // then it waits
            }
            await model.send(.deactivate) { $0 = .inactive }
            let reentry = await model.send(.active(.readAfterGate)) {  // re-enters the case
                $0 = .active(GatedChildState(value: 7))
            }

            writeGate.open()
            await task?.value
            await model.receive(.active(.bumpInPreamble)) {  // 7 + 100, then the bump's effect adds 1
                $0.modify(\.active) { $0.value = 108 }
            }
            readGate.open()
            await reentry?.value
            await model.finish()
        }

        #expect(issues == [])  // nothing "removed from the parent": the case is active again
        #expect(log.entries == ["send returned a task", "read value=108"])
    }
}
