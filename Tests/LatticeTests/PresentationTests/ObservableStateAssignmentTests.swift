import Observation
import Testing

@testable import Lattice

@FeatureState private struct Leaf: Equatable { var n: Int }
@FeatureState private struct Child: Equatable {
    var value: String
    var leaf: Leaf
}
@FeatureState private struct Parent: Equatable {
    var title: String
    var child: Child
}

/// A content-equal rebuild of a child state keeps the identities of the child and its nested
/// states. These tests run on the state value itself; `ViewModelObservationTests` covers the same
/// assignments through a `ViewModel`.
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
                a.child = Child(value: "x", leaf: Leaf(n: 1))  // a content-equal rebuild per tick
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
        withObservationTracking {
            _ = a.child.leaf.n
        } onChange: {
            fired = true
        }
        a.child = Child(value: "x", leaf: Leaf(n: 1))
        #expect(!fired)
    }

    @Test func contentChangeNotifies() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        nonisolated(unsafe) var fired = false
        withObservationTracking {
            _ = a.child.leaf.n
        } onChange: {
            fired = true
        }
        a.child = Child(value: "x", leaf: Leaf(n: 2))
        #expect(fired)
    }

    // A `ViewState` is a copy that shares the state's registrars, so reads through it are
    // notified exactly like reads on the state.
    @Test func projectionReadsShareTheStateRegistrars() {
        var a = Parent(title: "t", child: Child(value: "x", leaf: Leaf(n: 1)))
        let viewState = Parent.ViewState(a)
        nonisolated(unsafe) var fired = false
        withObservationTracking {
            _ = viewState.child.leaf.n
        } onChange: {
            fired = true
        }

        a.child = Child(value: "x", leaf: Leaf(n: 1))  // content-equal rebuild
        #expect(!fired)

        a.child.leaf.n = 2
        #expect(fired)
    }
}
