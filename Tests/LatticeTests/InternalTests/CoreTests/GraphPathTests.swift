import Testing

@testable import Lattice

extension CoreTests {
    @Suite
    struct GraphPathTests {

        @Test
        func sameAppendsAreEqualWithSameHash() {
            let a = GraphPath().appending(\S.child).appending(id: 0)
            let b = GraphPath().appending(\S.child).appending(id: 0)
            #expect(a == b)
            #expect(a.hashValue == b.hashValue)
        }

        @Test
        func keyPathComponentDiffersFromIDComponent() {
            let keyPath = GraphPath().appending(\S.child)
            let id = GraphPath().appending(id: AnyHashable(\S.child as AnyKeyPath))
            #expect(keyPath != id)
        }

        @Test
        func differentAppendsAreUnequal() {
            #expect(GraphPath().appending(\S.child) != GraphPath().appending(\S.n))
            #expect(GraphPath().appending(id: 0) != GraphPath().appending(id: 1))
            #expect(GraphPath() != GraphPath().appending(id: 0))
        }

        @Test
        func startsWithIsReflexive() {
            let path = GraphPath().appending(\S.child).appending(id: 1)
            #expect(path.starts(with: path))
        }

        @Test
        func parentIsPrefixOfChild() {
            let parent = GraphPath().appending(\S.child)
            let child = parent.appending(id: 0)
            #expect(child.starts(with: parent))
            #expect(!parent.starts(with: child))
        }

        @Test
        func siblingPositionalIndicesAreNotPrefixesOfEachOther() {
            let root = GraphPath().appending(\S.child)
            let first = root.appending(id: 0)
            let second = root.appending(id: 1)
            #expect(!first.starts(with: second))
            #expect(!second.starts(with: first))
        }

        @Test
        func emptyRootPathPrefixesEverything() {
            let root = GraphPath()
            #expect(GraphPath().starts(with: root))
            #expect(GraphPath().appending(\S.child).starts(with: root))
            #expect(GraphPath().appending(id: 3).appending(\S.n).starts(with: root))
        }

        @Test
        func branchTagsDistinguishBranchesAtSamePosition() {
            let base = GraphPath().appending(id: 0)
            let trueBranch = base.appending(id: "either.true")
            let falseBranch = base.appending(id: "either.false")
            #expect(trueBranch != falseBranch)
            #expect(!trueBranch.starts(with: falseBranch))
        }
    }
}
