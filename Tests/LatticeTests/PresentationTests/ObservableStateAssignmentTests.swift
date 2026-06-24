import Observation
import Testing

@testable import Lattice

@ObservableState private struct Leaf: Equatable { var n: Int }
@ObservableState private struct Child: Equatable { var value: String; var leaf: Leaf }
@ObservableState private struct Parent: Equatable { var title: String; var child: Child }

@Suite struct ObservableStateAssignmentTests {
    @Test func contentEqualRebuildPreservesNestedIdentity() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        let pid = a._$id, cid = a.child._$id, lid = a.child.leaf._$id

        a.child = Child(value: "x", leaf: Leaf(n: 1))  // content-equal wholesale rebuild

        #expect(a._$id == pid)
        #expect(a.child._$id == cid)
        #expect(a.child.leaf._$id == lid)
    }

    #if DEBUG
        @Test func contentEqualRebuildReusesStorageAcrossManyTicks() {
            var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
            let storage = a.child._$id._$storageObjectID

            for _ in 0..<1_000 {
                a.child = Child(value: "x", leaf: Leaf(n: 1))  // simulate reducer churn
            }

            #expect(a.child._$id._$storageObjectID == storage)  // one instance, not 1000
        }
    #endif

    @Test func contentChangeStillApplies() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        a.child = Child(value: "x", leaf: Leaf(n: 2))
        #expect(a.child == Child(value: "x", leaf: Leaf(n: 2)))
    }

    @Test func contentEqualRebuildDoesNotNotify() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        nonisolated(unsafe) var fired = false
        withObservationTracking { _ = a.child.leaf.n } onChange: { fired = true }
        a.child = Child(value: "x", leaf: Leaf(n: 1))
        #expect(!fired)
    }

    @Test func contentChangeNotifies() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        nonisolated(unsafe) var fired = false
        withObservationTracking { _ = a.child.leaf.n } onChange: { fired = true }
        a.child = Child(value: "x", leaf: Leaf(n: 2))
        #expect(fired)
    }
}
