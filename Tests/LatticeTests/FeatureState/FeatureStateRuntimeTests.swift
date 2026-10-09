import Foundation
import IdentifiedCollections
import Observation
import Testing
@testable import Lattice

@Suite
@MainActor
struct FeatureStateRuntimeTests {
    @Test
    func hiddenDependenciesAreNativeAndGettersAreNotMemoized() {
        let state = MutationState()
        let model = mutationModel(state)
        let changes = MutationProbe()
        observe({ _ = model.label }, changes)
        #expect(model.label == "0 items")
        #expect(state.probe.count("label") == 2)
        model.sendViewEvent(.noise)
        #expect(changes.count() == 0)
        model.sendViewEvent(.count(1)) // Equal output still invalidates the dependency.
        #expect(changes.count() == 1)
        #expect(model.label == "0 items")
        observe({ _ = model.label }, changes)
        model.sendViewEvent(.count(1))
        #expect(changes.count() == 1)
        model.sendViewEvent(.addZero)
        #expect(changes.count() == 2)
        model.sendViewEvent(.useAlternate(true))
        observe({ _ = model.label }, changes)
        model.sendViewEvent(.count(8))
        #expect(changes.count() == 2)
        model.sendViewEvent(.alternate(12))
        #expect(changes.count() == 3)
        #expect(model.label == "6 items")
        #expect(state.probe.count("rootEquality") == 0)
    }

    @Test
    func equatableRowsHaveIndependentLeafChannels() async throws {
        let state = MutationState()
        let model = mutationModel(state)
        let a = try #require(model.filteredRows.first { $0.id == 1 })
        let title = MutationProbe()
        let list = MutationProbe()
        observe({ _ = a.title }, title)
        observe({ _ = model.filteredRows }, list)
        model.sendViewEvent(.row(1, .sibling))
        #expect(title.count() == 0)
        #expect(list.count() == 1) // Raw-array/filter reads are legitimately broad.
        model.sendViewEvent(.row(2, .title("Bagels")))
        await model.sendViewEvent(.emitted(.row(2, .sibling))).finish()
        #expect(title.count() == 0)
        model.sendViewEvent(.row(1, .title("Cream")))
        #expect(title.count() == 1)
        #expect(a.title == "Cream")
        #expect(state.rows.allSatisfy { $0.probe.count("rowEquality") == 0 })
    }

    @Test
    func selectedRowsRefreshAtEverySentAndEmittedCommitWithoutReads() async throws {
        let state = MutationState()
        let model = mutationModel(state)
        let a = try #require(model.filteredRows.first { $0.id == 1 })
        #expect(state.probe.count("rows") == 1)
        model.sendViewEvent(.noise)
        #expect(state.probe.count("rows") == 2)
        model.sendViewEvent(.row(1, .title("Cream")))
        await model.sendViewEvent(.emitted(.row(1, .title("Oat milk")))).finish()
        // No row or result read between commits and disappearance.
        model.sendViewEvent(.row(1, .remove))
        #expect(a.title == "Oat milk")
        #expect(state.probe.count("rows") == 6) // normal read + five commits
        _ = model.filteredRows
        #expect(state.probe.count("rows") == 7)
    }

    @Test
    func omissionRetainsMilkAndSameLocationReinclusionReusesHeldHandle() throws {
        let model = mutationModel()
        let a = try #require(model.filteredRows.first { $0.id == 1 })
        let identity = a.handleIdentity
        model.sendViewEvent(.excludeAfterRename(1, "Oat milk"))
        #expect(a.title == "Milk")
        model.sendViewEvent(.row(1, .title("Hidden edit")))
        #expect(a.title == "Milk")
        let changes = MutationProbe()
        observe({ _ = a.title }, changes)
        model.sendViewEvent(.row(1, .eligible(true))) // No title mutation in this commit.
        #expect(changes.count() == 1)
        #expect(a.title == "Hidden edit")
        let reconnected = try #require(model.filteredRows.first { $0.id == 1 })
        #expect(reconnected.handleIdentity == identity)
        observe({ _ = a.title }, changes)
        model.sendViewEvent(.row(1, .title("Current")))
        #expect(changes.count() == 2)
        #expect(a.title == "Current")
    }

    @Test
    func freshEqualRowReplacementSwitchesChannelsWithoutRowEquality() throws {
        let original = MutationRow(id: 1, title: "Milk")
        let model = mutationModel(MutationState(rows: [original]))
        let a = try #require(model.filteredRows.first { $0.id == 1 })
        let changes = MutationProbe()
        let listChanges = MutationProbe()
        observe({ _ = a.title }, changes)
        observe({ _ = model.filteredRows }, listChanges)
        let fresh = MutationRow(id: 1, title: "Milk")
        model.sendViewEvent(.replaceRows([fresh]))
        #expect(changes.count() == 1)
        #expect(listChanges.count() == 1)
        #expect(original.probe.count("rowEquality") == 0)
        #expect(fresh.probe.count("rowEquality") == 0)
        observe({ _ = a.title }, changes)
        model.sendViewEvent(.row(1, .sibling))
        #expect(changes.count() == 1)
        model.sendViewEvent(.row(1, .title("New channel")))
        #expect(changes.count() == 2)
        #expect(a.title == "New channel")
    }

    @Test
    func optionalParentAndOrdinaryDescendantsRetainApplicableCommits() async throws {
        let state = MutationState()
        let model = mutationModel(state)
        let parent = try #require(model.scopeIfPresent(state: \.parent, action: \.parent))
        let detail = parent.scope(state: \.detail, action: { $0 })
        model.sendViewEvent(.parent(.title("Sent")))
        await model.sendViewEvent(.emitted(.parent(.title("Emitted")))).finish()
        model.sendViewEvent(.parent(.secret(7)))
        model.sendViewEvent(.removeParentAfterEdit)
        #expect(model.scopeIfPresent(state: \.parent) == nil)
        #expect(detail.title == "Emitted")
        #expect(detail.label == "Emitted:7")
        let createdAfterAbsence = parent.scope(state: \.detail)
        #expect(createdAfterAbsence.label == "Emitted:7")
        let nestedRows = parent.filteredRows
        #expect(nestedRows.first?.title == "Nested")
        detail.binding(\.title, sending: \.title).wrappedValue = "While absent"
        #expect(state.probe.count("parentActions") == 4)
        #expect(detail.title == "Emitted")
        var restored = state.parent!
        restored.detail.title = "Reconnected"
        let changes = MutationProbe()
        observe({ _ = createdAfterAbsence.title }, changes)
        model.sendViewEvent(.restoreParent(restored))
        #expect(changes.count() == 1)
        #expect(detail.title == "Reconnected")
        #expect(createdAfterAbsence.title == "Reconnected")
    }

    @Test
    func nestedResultDescendantsNeverFollowExcludedSource() throws {
        let model = mutationModel()
        let a = try #require(model.filteredRows.first { $0.id == 1 })
        let child = a.scope(state: \.detail)
        model.sendViewEvent(.row(1, .eligible(false)))
        let firstReadAfterOmission = a.scope(state: \.detail)
        #expect(firstReadAfterOmission.title == "Detail")
        var replacement = MutationRow(id: 1, title: "Hidden", eligible: false)
        replacement.detail.title = "Hidden detail"
        model.sendViewEvent(.replaceRows([replacement]))
        #expect(child.title == "Detail")
        #expect(firstReadAfterOmission.title == "Detail")
        model.sendViewEvent(.row(1, .eligible(true)))
        #expect(child.title == "Hidden detail")
        #expect(firstReadAfterOmission.title == "Hidden detail")
    }

    @Test
    func callbacksReadOldWorkingCopyCommitAndObserverSendsAreFIFO() {
        let model = mutationModel()
        let callbacks = MutationProbe()
        // Mutation is synchronously driven here on MainActor. This actor
        // assumption is test-only and is never used for background copy tests.
        withObservationTracking { _ = model.label } onChange: {
            MainActor.assumeIsolated {
                callbacks.append("label:\(model.label),ticket:\(model.ticket)")
                model.sendViewEvent(.ticket(99))
                callbacks.append("buffered:\(model.ticket)")
            }
        }
        withObservationTracking { _ = model.ticket } onChange: {
            MainActor.assumeIsolated { callbacks.append("ticket:\(model.ticket)") }
        }
        model.sendViewEvent(.pair(6, 3))
        #expect(callbacks.log == ["label:0 items,ticket:0", "buffered:0", "ticket:0"])
        #expect(model.label == "3 items")
        #expect(model.ticket == 99)
        let changes = MutationProbe()
        observe({ _ = model.label }, changes)
        model.sendViewEvent(.count(8))
        #expect(changes.count() == 1)
    }

    @Test
    func structuralCallbacksSeeAllStagedSlotsAndCanRegisterAndSend() throws {
        let model = mutationModel()
        let a = try #require(model.filteredRows.first { $0.id == 1 })
        let parent = try #require(model.scopeIfPresent(state: \.parent))
        let detail = parent.scope(state: \.detail)
        let callbacks = MutationProbe()
        withObservationTracking { _ = a.title } onChange: {
            MainActor.assumeIsolated {
                callbacks.append("\(a.title)/\(detail.title)/\(model.label)")
                let newScope = model.scope(state: \.child)
                callbacks.append(newScope.title)
                model.sendViewEvent(.ticket(44))
            }
        }
        var replacement = MutationState(count: 10)
        replacement.rows = [MutationRow(id: 1, title: "Replacement")]
        replacement.parent?.detail.title = "New parent"
        replacement.child.title = "New child"
        model.sendViewEvent(.reset(replacement))
        #expect(callbacks.log == ["Replacement/New parent/5 items", "New child"])
        #expect(model.ticket == 44)
        let changes = MutationProbe()
        observe({ _ = detail.title }, changes)
        model.sendViewEvent(.parent(.title("Next")))
        #expect(changes.count() == 1)
    }

    @Test
    func callbackTimeMaterializationEnrollsBeforeTheCommit() {
        let state = MutationState()
        let model = mutationModel(state)
        let capture = CapturedScopes()
        withObservationTracking { _ = model.label } onChange: {
            MainActor.assumeIsolated {
                capture.parent = model.scopeIfPresent(state: \.parent)
                capture.row = model.filteredRows.first { $0.id == 1 }
            }
        }
        var next = state
        next.parent?.detail.title = "Committed"
        // Same-channel callback occurs before this copy is installed.
        next.count = 2
        model.sendViewEvent(.reset(next))
        model.sendViewEvent(.removeParentAfterEdit)
        #expect(capture.parent?.scope(state: \.detail).title == "Committed")
        #expect(capture.row?.title == "Milk")
    }

    @Test
    func sameLocationDelayedCopyAssignmentDoesNotReplayNotifications() {
        let original = MutationState()
        let model = mutationModel(original)
        let child = model.scope(state: \.child)
        let changes = MutationProbe()
        observe({ _ = child.title }, changes)
        var detached = original
        detached.child.title = "Detached"
        #expect(changes.count() == 1)
        #expect(child.title == "Detail")
        observe({ _ = child.title }, changes)
        model.sendViewEvent(.reset(detached))
        #expect(changes.count() == 1)
        #expect(child.title == "Detached")
    }

    @Test
    func materializedScopesAndResultsAreARCAndBounded() throws {
        var model: MutationModel? = mutationModel()
        let weakModel = WeakMutationModel(model)
        var held: ScopedRowViewModel<MutationRow>? = model?.filteredRows.first
        for _ in 0..<100 {
            _ = model?.scope(state: \.child)
            _ = model?.scopeIfPresent(state: \.parent)?.scope(state: \.detail)
        }
        model?.sendViewEvent(.noise)
        #expect(model!.featureStateRegistrationCount == 1) // materialized root result only
        model?.sendViewEvent(.replaceRows([]))
        #expect(model?.filteredRows.isEmpty == true)
        model = nil
        #expect(weakModel.value != nil)
        #expect(held?.title != nil)
        held = nil
        #expect(weakModel.value == nil)
    }

    @Test
    func backgroundCopyNotifiesHeldRowOffActorWithoutReconcilingTheModel() async throws {
        let original = MutationState()
        let model = mutationModel(original)
        let row = try #require(model.filteredRows.first { $0.id == 1 })
        let probe = MutationProbe()
        let hopped = CancellationProbe()
        withObservationTracking { _ = row.title } onChange: {
            probe.increment(Thread.isMainThread ? "main" : "background")
            Task { @MainActor in
                probe.append(row.title)
                await hopped.markStarted()
            }
        }
        let mutated = await Task.detached {
            var copy = original
            copy.rows[0].title = "Background"
            return copy
        }.value
        await hopped.waitUntilStarted()
        #expect(probe.count("background") == 1)
        #expect(probe.count("main") == 0)
        #expect(probe.log == ["Milk"])
        #expect(row.title == "Milk")
        #expect(mutated.rows[0].title == "Background")
        #expect(original.probe.count("rows") == 1)
    }

    @Test
    func twoModelsShareChannelsButNotCommittedValues() {
        let state = MutationState()
        let first = mutationModel(state)
        let second = mutationModel(state)
        let firstChanges = MutationProbe()
        let secondChanges = MutationProbe()
        observe({ _ = first.label }, firstChanges)
        observe({ _ = second.label }, secondChanges)
        first.sendViewEvent(.count(6))
        #expect(firstChanges.count() == 1)
        #expect(secondChanges.count() == 1)
        #expect(first.label == "3 items")
        #expect(second.label == "0 items")
    }

    @Test
    func testViewModelAssertionCopiesDoNotCorruptPreviousOrActualState() async {
        let original = MutationState()
        let model = TestViewModel(
            initialDomainState: original,
            feature: Feature<MutationAction, MutationState, _FeatureStatePresentation>(
                interactor: MutationInteractor(probe: original.probe)
            )
        )
        await model.send(.child(.title("Asserted"))) { $0.child.title = "Asserted" }
        let previous = model.domainState
        await model.send(.child(.sibling)) { $0.child.sibling = 1 }
        #expect(model.domainState.child.title == "Asserted")
        #expect(model.domainState.child.sibling == 1)
        #expect(previous.child.sibling == 0)
        #expect(original.child.title == "Detail")
        await model.finish()
    }

    @Test
    func observerSendIsBufferedThroughEffectEnrollmentAndHasItsOwnEventTask() async throws {
        let rootProbe = CancellationProbe()
        let observerProbe = CancellationProbe()
        let log = MutationProbe()
        let capture = CapturedLoopModel()
        let interactor = Interact<MutationState, LoopAction> { state, action in
            switch action {
            case .root:
                state.count = 2
                return suspendedEmission(rootProbe)
            case .observer:
                // The action is reached only through this MainActor-owned model.
                MainActor.assumeIsolated {
                    let effects = Mirror(reflecting: capture.model!).children.first { $0.label == "effectTasks" }?.value
                    log.append("enrolled:\(effects.map { Mirror(reflecting: $0).children.count } ?? -1)")
                }
                state.ticket = 1
                return suspendedEmission(observerProbe)
            }
        }
        let model = ViewModel(initialDomainState: MutationState(), feature: Feature(interactor: interactor))
        capture.model = model
        withObservationTracking { _ = model.label } onChange: {
            MainActor.assumeIsolated {
                log.append(model.label)
                capture.observerTask = model.sendViewEvent(.observer)
                log.append("buffered:\(model.ticket)")
            }
        }
        let rootTask = model.sendViewEvent(.root)
        let observerTask = try #require(capture.observerTask)
        #expect(log.log == ["0 items", "buffered:0", "enrolled:1"])
        #expect(model.ticket == 1)
        await rootProbe.waitUntilStarted()
        await observerProbe.waitUntilStarted()
        rootTask.cancel()
        await rootTask.finish()
        #expect(await rootProbe.cancelled())
        #expect(await observerProbe.cancelled() == false)
        observerTask.cancel()
        await observerTask.finish()
        #expect(await observerProbe.cancelled())
    }

    @Test
    func realEventTaskStillWaitsForTransitiveEmissions() async {
        let model = mutationModel()
        await model.sendViewEvent(.chain).finish()
        #expect(model.label == "11 items")
    }
}

@MainActor
private final class WeakMutationModel {
    weak var value: MutationModel?
    init(_ value: MutationModel?) { self.value = value }
}

private enum LoopAction: Sendable { case root, observer }

@MainActor
private final class CapturedLoopModel {
    weak var model: ViewModel<Feature<LoopAction, MutationState, _FeatureStatePresentation>>?
    var observerTask: EventTask?
}

private func suspendedEmission(_ probe: CancellationProbe) -> Emission<LoopAction> {
    .perform {
        await probe.markStarted()
        await withTaskCancellationHandler {
            await probe.suspendUntilCancelled()
        } onCancel: {
            Task { await probe.cancel() }
        }
        return nil
    }
}

@MainActor
private final class CapturedScopes {
    var parent: ScopedViewModel<MutationParent, Never>?
    var row: ScopedRowViewModel<MutationRow>?
}

@MainActor
private func observe(_ read: () -> Void, _ probe: MutationProbe) {
    withObservationTracking(read) { probe.increment() }
}

@Suite
struct FeatureStateCopyTests {
    @Test
    func generatedRootRowOptionalAndGenericStorageShareThenDetach() {
        let original = MutationState()
        var copy = original
        #expect(storageID(original, "child", MutationDetail.self) == storageID(copy, "child", MutationDetail.self))
        #expect(storageID(original, "parent", MutationParent?.self) == storageID(copy, "parent", MutationParent?.self))
        let changes = MutationProbe()
        withObservationTracking { _ = original.child.title } onChange: { changes.increment() }
        copy.child.title = "Copy"
        #expect(copy.child.title == "Copy")
        #expect(original.child.title == "Detail")
        #expect(changes.count() == 1)
        #expect(original._featureStateIdentity == copy._featureStateIdentity)
        #expect(original.child._featureStateIdentity == copy.child._featureStateIdentity)
        #expect(storageID(original, "child", MutationDetail.self) != storageID(copy, "child", MutationDetail.self))
        copy.parent?.detail.sibling += 1
        #expect(original.parent?.detail.sibling == 0)
        #expect(copy.parent?.detail.sibling == 1)
        #expect(storageID(original, "parent", MutationParent?.self) != storageID(copy, "parent", MutationParent?.self))
        var setterCopy = original
        setterCopy.parent = original.parent // Equal setter still detaches shared storage.
        #expect(storageID(original, "parent", MutationParent?.self) != storageID(setterCopy, "parent", MutationParent?.self))
        setterCopy.child = MutationDetail(title: "Replacement")
        #expect(original.child.title == "Detail")
        var row = original.rows[0]
        let rowCopy = row
        #expect(storageID(row, "detail", MutationDetail.self) == storageID(rowCopy, "detail", MutationDetail.self))
        row.detail.title = "Changed row"
        #expect(rowCopy.detail.title == "Detail")
        #expect(storageID(row, "detail", MutationDetail.self) != storageID(rowCopy, "detail", MutationDetail.self))
        let generic = MutationGeneric(value: MutationDetail(), optional: MutationDetail())
        var genericCopy = generic
        #expect(storageID(generic, "value", MutationDetail.self) == storageID(genericCopy, "value", MutationDetail.self))
        genericCopy.value.sibling += 1
        genericCopy.optional?.title = "Generic"
        #expect(generic.value.sibling == 0)
        #expect(generic.optional?.title == "Detail")
        #expect(storageID(generic, "value", MutationDetail.self) != storageID(genericCopy, "value", MutationDetail.self))
    }

    @Test
    func uniqueStorageMutatesInPlaceAndEquatableAggregateSiblingsStayQuiet() {
        var state = MutationState()
        let initialBox = storageID(state, "child", MutationDetail.self)
        let changes = MutationProbe()
        withObservationTracking { _ = state.child.title } onChange: { changes.increment() }
        state.child.sibling += 1
        #expect(changes.count() == 0)
        #expect(storageID(state, "child", MutationDetail.self) == initialBox)
        state.child = MutationDetail(sibling: 1) // Fresh, content-equal aggregate.
        #expect(changes.count() == 1)
        withObservationTracking { _ = state.child.title } onChange: { changes.increment() }
        state.child.title = "New tree"
        #expect(changes.count() == 2)
        #expect(storageID(state, "count", Int.self) == nil)
    }

    @Test
    func backgroundCopiesNotifyOnMutatingExecutorWithoutChangingCommittedValues() async {
        let state = MutationState()
        let probe = MutationProbe()
        withObservationTracking { _ = state.child.title } onChange: {
            probe.increment(Thread.isMainThread ? "main" : "background")
        }
        let copy = await Task.detached {
            var copy = state
            copy.child.title = "Background"
            return copy
        }.value
        #expect(probe.count("background") == 1)
        #expect(probe.count("main") == 0)
        #expect(state.child.title == "Detail")
        #expect(copy.child.title == "Background")
    }

    @Test
    func concurrentSeparateCopiesKeepValuesIndependent() async {
        let state = MutationState()
        let values = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for number in 0..<64 {
                group.addTask {
                    var copy = state
                    copy.parent?.detail.sibling = number
                    copy.rows[0].detail.sibling += number
                    return copy.parent!.detail.sibling + copy.rows[0].detail.sibling
                }
            }
            var results: [Int] = []
            for await value in group { results.append(value) }
            return results.sorted()
        }
        #expect(values == (0..<64).map { $0 * 2 })
        #expect(state.parent?.detail.sibling == 0)
        #expect(state.rows[0].detail.sibling == 0)
    }
}

private func storageID<Value>(_ state: Any, _ field: String, _: Value.Type) -> ObjectIdentifier? {
    let wrapper = Mirror(reflecting: state).children.first { $0.label == "_feature_\(field)" }?.value
    return (wrapper as? _FeatureStateTracked<Value>)?.storageIdentity
}

@FeatureState
private struct MutationObserverState: Sendable {
    @Domain var probe: MutationProbe
    var child: MutationDetail = MutationDetail() {
        willSet { probe.append("will:\(child.title)") }
        didSet { probe.append("did:\(child.title)") }
    }
}

extension FeatureStateCopyTests {
    @Test
    func propertyObserversStillRunForEqualAssignmentAndModifyOnCopiedStorage() {
        let probe = MutationProbe()
        let original = MutationObserverState(probe: probe)
        var copy = original
        let changes = MutationProbe()
        withObservationTracking { _ = original.child.title } onChange: { changes.increment() }
        copy.child = original.child
        #expect(changes.count() == 0)
        copy.child.title = "Copy"
        #expect(changes.count() == 1)
        #expect(original.child.title == "Detail")
        #expect(copy.child.title == "Copy")
        #expect(probe.log == ["will:Detail", "did:Detail", "will:Detail", "did:Copy"])
    }
}

@FeatureState
private struct PrefixedMutationInput: Sendable {
    @Domain var _featureInput: Int = 0
    var label: String { "\(_featureInput)" }
}

extension FeatureStateCopyTests {
    @Test
    func similarlyPrefixedUserInputIsStillTracked() {
        let original = PrefixedMutationInput()
        var copy = original
        let changes = MutationProbe()
        withObservationTracking { _ = original.label } onChange: { changes.increment() }
        copy._featureInput = 1
        #expect(changes.count() == 1)
        #expect(original.label == "0")
        #expect(copy.label == "1")
    }
}

@FeatureState
private struct TrackedCollectionAssignmentState: Sendable {
    var rows: [MutationRow]
    var identified: IdentifiedArrayOf<MutationRow>
    @Domain var optionalRows: [MutationRow]?
    var numbers: [Int] = [1]
}

extension FeatureStateCopyTests {
    @Test
    func trackedCollectionSettersDoNotCompareRowsAndLeafCollectionEqualityIsUnchanged() {
        let control = MutationRow(id: 1, title: "Milk")
        #expect([control] == [MutationRow(id: 1, title: "Milk")])
        #expect(control.probe.count("rowEquality") == 1)

        let originalRow = MutationRow(id: 1, title: "Milk")
        let original = TrackedCollectionAssignmentState(
            rows: [originalRow], identified: [originalRow], optionalRows: [originalRow]
        )
        var copy = original
        let changes = MutationProbe()
        withObservationTracking { _ = original.rows } onChange: { changes.increment("rows") }
        withObservationTracking { _ = original.identified } onChange: { changes.increment("identified") }
        withObservationTracking { _ = original.optionalRows } onChange: { changes.increment("optional") }
        withObservationTracking { _ = original.numbers } onChange: { changes.increment("numbers") }
        let replacement = MutationRow(id: 1, title: "Milk")
        copy.rows = [replacement]
        copy.identified = [replacement]
        copy.optionalRows = [replacement]
        copy.numbers = [1]
        #expect(originalRow.probe.count("rowEquality") == 0)
        #expect(replacement.probe.count("rowEquality") == 0)
        #expect(changes.count("rows") == 1)
        #expect(changes.count("identified") == 1)
        #expect(changes.count("optional") == 1)
        #expect(changes.count("numbers") == 0)
        copy.numbers = [2]
        #expect(changes.count("numbers") == 1)
        #expect(original.numbers == [1])
        #expect(copy.numbers == [2])
    }
}
