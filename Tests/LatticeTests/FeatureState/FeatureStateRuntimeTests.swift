@testable import Lattice
import Testing

@FeatureState
private struct DescriptorGateChild: Equatable {
    var title: String = "Visible"
    @Domain var secret: Int = 7
}

@FeatureState
private struct DescriptorGateRoot<Value: Equatable> {
    var value: Value
    var child: DescriptorGateChild = DescriptorGateChild()
}

@Suite
@MainActor
struct FeatureStateRuntimeTests {
    @Test
    func descriptorReadsFollowCurrentState() {
        var state = DescriptorGateRoot(value: 42)
        let projection = FeatureProjection(read: { state })
        let child: FeatureProjection<DescriptorGateChild> = projection.child
        #expect(projection.value == 42)
        #expect(DescriptorGateRoot<Int>._viewMembers.value.areEqual(42, 42))
        #expect(!DescriptorGateRoot<Int>._viewMembers.value.areEqual(42, 43))
        #expect(projection.child.title == "Visible")
        #expect(child.title == "Visible")
        state.value = 43
        state.child.title = "Updated"
        #expect(projection.value == 43)
        #expect(child.title == "Updated")
    }
}

extension FeatureStateRuntimeTests {
    @Test
    func derivedCachingEqualityAndEverAccessedMaintenance() {
        let host = FeatureStateHost(ObservedState())
        let view = host.projection
        let counts = host.state.counts
        host.update { $0.input = 1 }
        #expect(counts.label == 0)
        #expect(view.label == "0")
        #expect(view.label == "0")
        #expect(counts.label == 1)
        let changes = ChangeCount()
        track({ _ = view.label }, changes)
        host.update { $0.input = 2 }
        #expect(changes.value == 1)
        #expect(counts.label == 2)
        host.update { $0.input = 3 }
        #expect(changes.value == 1) // Observation tracking is one-shot, cache is not.
        #expect(counts.label == 3)
        #expect(view.label == "1")
        track({ _ = view.label }, changes)
        host.update { $0.input = 4 }
        #expect(changes.value == 2)
    }

    @Test
    func nilCachingAndOrdinaryCrossGetterCalls() {
        let host = FeatureStateHost(ObservedState())
        let view = host.projection
        let counts = host.state.counts
        #expect(view.nilValue == nil)
        #expect(view.nilValue == nil)
        #expect(counts.nilValue == 1)
        #expect(view.combined == "0other 0")
        #expect(counts.combined == 1)
        #expect(counts.label == 1)
        #expect(view.label == "0") // Raw call from combined did not cache label.
        #expect(counts.label == 2)
        host.update { $0.input = 2 }
        #expect(counts.nilValue == 2)
        #expect(counts.combined == 2)
        #expect(counts.label == 4) // One direct slot, one ordinary combined call.
    }

    @Test
    func callbacksSeePublishedStoredAndAllDerivedOutputs() {
        let host = FeatureStateHost(ObservedState())
        let view = host.projection
        let changes = ChangeCount()
        withObservationTracking {
            _ = view.stored
            _ = view.label
            _ = view.other
        } onChange: {
            MainActor.assumeIsolated {
                changes.value += 1
                #expect(view.stored == 9)
                #expect(view.label == "2")
                #expect(view.other == "other 4")
            }
        }
        host.update { $0.stored = 9; $0.input = 4 }
        #expect(changes.value == 1)
        #expect(host.state.counts.label == 2)
        #expect(host.state.counts.other == 2)
    }

    @Test
    func inlineStoredChildIsGranularAndUsesDerivedCache() {
        let host = FeatureStateHost(ObservedState())
        let view = host.projection
        let changes = ChangeCount()
        track({ _ = view.child.label }, changes)
        #expect(view.child.label == "0")
        #expect(host.state.child.counts.label == 1)
        host.update { $0.child.title = "Unrelated" }
        #expect(changes.value == 0)
        host.update { $0.child.input = 1 }
        #expect(changes.value == 1)
        #expect(view.child.label == "1")
    }

    @Test
    func computedStructuresAreCoarseAndCoherent() {
        let host = FeatureStateHost(ObservedState())
        let view = host.projection
        let child = view.computedChild
        let optional = view.computedOptional!
        let rows = view.computedRows
        let changes = ChangeCount()
        withObservationTracking {
            _ = child.label
            _ = optional.title
            _ = rows.ids
        } onChange: {
            MainActor.assumeIsolated {
                changes.value += 1
                #expect(child.label == "2")
                #expect(optional.title == "2")
                #expect(Array(rows.ids) == [2])
            }
        }
        host.update { $0.input = 2 }
        #expect(changes.value == 1)
        #expect(host.state.counts.child == 2)
        #expect(host.state.counts.optional == 2)
        #expect(host.state.counts.rows == 2)
        host.update { $0.show = false }
        #expect(view.computedOptional == nil)
        #expect(rows.isEmpty)
    }

    @Test
    func heldOptionalUsesCreationSnapshotWithoutPoisoningLiveCache() {
        let host = FeatureStateHost(ObservedState())
        let view = host.projection
        let held = view.optional!
        #expect(held.label == "0")
        host.update { $0.optional?.input = 2 }
        #expect(held.label == "2")
        host.update { $0.optional = nil }
        #expect(view.optional == nil)
        #expect(held.label == "0")
        host.update { $0.optional = ObservedChild(input: 7) }
        #expect(held.label == "7")
        #expect(view.optional?.label == "7")
    }

    @Test
    func identifiedRowsPruneAndReappearWithoutStaleOutputs() {
        let host = FeatureStateHost(ObservedState(rows: [ObservedRow(id: 1, title: "One"), ObservedRow(id: 2, title: "Two")]))
        let rows = host.projection.rows
        let held = rows[id: 1]!
        let rowChanges = ChangeCount()
        let structureChanges = ChangeCount()
        track({ _ = held.label }, rowChanges)
        track({ _ = rows.ids }, structureChanges)
        host.update { $0.rows[id: 2]?.input = 2 }
        #expect(rowChanges.value == 0)
        #expect(structureChanges.value == 0)
        host.update { $0.rows.reverse() }
        #expect(structureChanges.value == 1)
        #expect(rowChanges.value == 0)
        host.update { $0.rows.remove(id: 1) }
        #expect(rowChanges.value == 1)
        #expect(rows[id: 1] == nil)
        #expect(held.label == "0")
        host.update { $0.rows.append(ObservedRow(id: 1, title: "New", input: 9)) }
        #expect(held.label == "9")
        #expect(rows[id: 1]?.label == "9")
    }

    @Test
    func absentReadersTrackReappearanceAndNestedSnapshotsStayDetached() {
        let host = FeatureStateHost(ObservedState(rows: [ObservedRow(id: 1, title: "Initial")]))
        let view = host.projection
        let row = view.rows[id: 1]!
        host.update { $0.rows.remove(id: 1) }
        let changes = ChangeCount()
        track({ _ = row.label }, changes)
        host.update { $0.rows.append(ObservedRow(id: 1, title: "New", input: 8)) }
        #expect(changes.value == 1)
        #expect(row.label == "8")

        let phase = FeatureStateHost(ObservedPhase.nested(.ready(CoarseChild(title: "Initial", input: 1))))
        let heldParent = phase.projection.nested!
        phase.update { $0 = .idle }
        let heldChild = heldParent.ready! // Created from a detached parent snapshot.
        #expect(heldChild.label == "1")
        phase.update { $0 = .nested(.ready(CoarseChild(title: "Current", input: 9))) }
        #expect(heldChild.label == "9")
    }

    @Test
    func computedOptionalNilIsCachedAndStoredOptionalShapeIsObserved() {
        let host = FeatureStateHost(ObservedState(show: false, optional: nil))
        let view = host.projection
        #expect(view.computedOptional == nil)
        #expect(view.computedOptional == nil)
        #expect(host.state.counts.optional == 1)
        let changes = ChangeCount()
        track({ _ = view.optional }, changes)
        host.update { $0.optional = ObservedChild(input: 3) }
        #expect(changes.value == 1)
        #expect(host.state.counts.optional == 2)
        #expect(view.optional?.label == "3")
        host.update { $0.show = true }
        #expect(view.computedOptional?.title == "0")
    }

    @Test
    func enumCaseAndNestedHeldSnapshot() {
        let host = FeatureStateHost(ObservedPhase.nested(.ready(CoarseChild(title: "Initial"))))
        let held = host.projection.nested!.ready!
        let changes = ChangeCount()
        track({ _ = held.title }, changes)
        host.update { $0 = .idle }
        #expect(changes.value == 1)
        #expect(host.projection.nested == nil)
        #expect(held.title == "Initial")
        host.update { $0 = .nested(.ready(CoarseChild(title: "Current"))) }
        #expect(held.title == "Current")
    }
}

import Observation

@MainActor
private final class ChangeCount { var value = 0 }

@MainActor
private func track(_ read: () -> Void, _ changes: ChangeCount) {
    withObservationTracking(read) {
        MainActor.assumeIsolated { changes.value += 1 }
    }
}
