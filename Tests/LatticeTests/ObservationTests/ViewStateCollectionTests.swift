import IdentifiedCollections
import Testing

@testable import Lattice

@Suite struct ViewStateCollectionTests {
    private let players = [PlayerState(id: 1, score: 10), PlayerState(id: 2, score: 20)]

    @Test func indicesAreTheBaseCollectionIndices() {
        let collection = ViewStateCollection(IdentifiedArrayOf<PlayerState>(uniqueElements: players))
        #expect(collection.startIndex == 0)
        #expect(collection.endIndex == 2)
        #expect(collection.index(after: 0) == 1)
        #expect(collection.index(before: 2) == 1)
        #expect(collection.count == 2)
        #expect(collection.ids == 0..<2)
    }

    @Test func elementsAreProjectedLazily() {
        let collection = ViewStateCollection(players)
        #expect(type(of: collection[0]) == PlayerState.ViewState.self)
        #expect(collection[1].score == 20)
        #expect(collection.map(\.id) == [1, 2])
        #expect(collection.reversed().map(\.score) == [20, 10])
    }

    @Test func identifiedArrayLookupProjectsTheElement() {
        let collection = ViewStateCollection(IdentifiedArrayOf<PlayerState>(uniqueElements: players))
        #expect(collection[id: 2]?.score == 20)
        #expect(collection[id: 3] == nil)
    }

    @Test func emptyCollection() {
        let collection = ViewStateCollection([PlayerState]())
        #expect(collection.isEmpty)
        #expect(collection.ids.isEmpty)
    }
}
