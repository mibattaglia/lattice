// Plan 05 §12 gate A: hand-expansion granularity + diff-tier tests against a stub host
// (a bare `FeatureStateRegistrar` + closure-held state; no `LatticeCore`). Phase B swaps
// the fixtures over to the real macro; this file must not change in that swap.

import IdentifiedCollections
import Testing

@testable import Lattice

// MARK: - Stub host

@MainActor
private final class StubHost<State: FeatureStateProtocol> {
    private(set) var state: State
    let registrar = FeatureStateRegistrar()

    /// Pokes delivered during the most recent `commit`.
    private(set) var pokes: [ProjectionKey] = []

    init(_ state: State) {
        self.state = state
        registrar.onPoke = { [weak self] key in self?.pokes.append(key) }
    }

    var projection: FeatureProjection<State> {
        FeatureProjection(
            read: { [weak self] in self!.state },
            registrar: registrar,
            key: ProjectionKey()
        )
    }

    @discardableResult
    func commit(_ mutate: (inout State) -> Void) -> [ProjectionKey] {
        let old = state
        mutate(&state)
        pokes = []
        registrar.commit {
            State._commit(old: old, new: state, registrar: registrar, key: ProjectionKey())
        }
        return pokes
    }
}

@MainActor private let root = ProjectionKey()

@Suite(.serialized)
@MainActor
struct FeatureStateRuntimeTests {

    // MARK: Leaf tier

    @Test
    func leafFireAndSkip() {
        let host = StubHost(SearchState())
        let queryKey = root.appending(\SearchState._ViewMembers.query)
        _ = host.projection.query  // register

        #expect(host.commit { $0.query = "a" } == [queryKey])
        #expect(host.commit { $0.query = "a" }.isEmpty)  // unchanged value: skip
        #expect(host.commit { $0.isLoading = true }.isEmpty)  // unread leaf: no signal
    }

    @Test
    func domainOnlyCommitFiresNothing() {
        let host = StubHost(SearchState())
        _ = host.projection.query
        registrarAccessRoot(host.registrar)
        #expect(host.commit { $0.rawResults = [SearchResult(id: 1, name: "x")] }.isEmpty)
    }

    // MARK: Derived members — gating, caching, evaluation counts

    @Test
    func derivedOutputEqualityGating() {
        let host = StubHost(SearchState(rawResults: [SearchResult(id: 1, name: "a")]))
        _ = host.projection.subtitle  // seed the cache
        // Input changed, output identical (same count) ⇒ no fire.
        let pokes = host.commit { $0.rawResults = [SearchResult(id: 2, name: "b")] }
        #expect(pokes.isEmpty)
        // Output changes ⇒ one fire on the derived key.
        let subtitleKey = root.appending(\SearchState._ViewMembers.subtitle)
        #expect(host.commit { $0.rawResults = [] } == [subtitleKey])
        #expect(host.projection.subtitle == "0 results")
    }

    @Test
    func observerGatedSkip() {
        FixtureCounters.reset()
        let host = StubHost(DetailState())
        _ = host.projection.title  // observe something else, never `display`
        host.commit { $0.title = "a" }
        host.commit { $0.badge = 7 }
        #expect(FixtureCounters.count("DetailState.display") == 0)
    }

    @Test
    func singleComputePerCommitWhileObserved() {
        FixtureCounters.reset()
        let host = StubHost(DetailState())
        _ = host.projection.display  // first read seeds: one evaluation
        #expect(FixtureCounters.count("DetailState.display") == 1)
        host.commit { $0.title = "x" }  // exactly one evaluation per commit
        #expect(FixtureCounters.count("DetailState.display") == 2)
        host.commit { $0.badge = 3 }
        #expect(FixtureCounters.count("DetailState.display") == 3)
    }

    @Test
    func readsServedFromCache() {
        FixtureCounters.reset()
        let host = StubHost(DetailState(title: "t"))
        #expect(host.projection.display == "t")
        #expect(host.projection.display == "t")
        #expect(host.projection.display == "t")
        #expect(FixtureCounters.count("DetailState.display") == 1)  // seed once, then cache
        host.commit { $0.title = "u" }
        #expect(host.projection.display == "u")  // served from the recommitted cache
        #expect(FixtureCounters.count("DetailState.display") == 2)
    }

    @Test
    func cacheCorrectnessRandomizedMutationSequence() {
        var generator = SplitMix64(seed: 0x05_FEA7)
        let host = StubHost(TransactionsState())
        _ = host.projection.visibleOrder
        _ = host.projection.emptyMessage

        for iteration in 0..<200 {
            host.commit { state in
                switch Int.random(in: 0..<5, using: &generator) {
                case 0:
                    state.transactions.append(
                        Transaction(
                            id: iteration,
                            amount: Int.random(in: 0..<100, using: &generator),
                            merchantName: "m\(iteration)",
                            postedAt: Int.random(in: 0..<1000, using: &generator)
                        )
                    )
                case 1:
                    if let id = state.transactions.ids.randomElement(using: &generator) {
                        state.transactions.remove(id: id)
                    }
                case 2:
                    if let id = state.transactions.ids.randomElement(using: &generator) {
                        state.transactions[id: id]?.amount = Int.random(
                            in: 0..<100, using: &generator)
                    }
                case 3:
                    if let id = state.transactions.ids.randomElement(using: &generator) {
                        state.transactions[id: id]?.flagged.toggle()
                    }
                default:
                    state.filter.minAmount = Int.random(in: 0..<100, using: &generator)
                }
            }
            // Observe a random element's derived members too (seeds per-element caches).
            if let id = host.state.transactions.ids.randomElement(using: &generator),
                let row = host.projection.transactions[id: id]
            {
                #expect(row.title == host.state.transactions[id: id]?.merchantName)
                #expect(row.icon == (host.state.transactions[id: id]!.flagged ? "flag" : "circle"))
            }
            // Cache correctness: the projection's cached outputs equal a fresh computation
            // from committed state after every commit.
            #expect(host.projection.visibleOrder == host.state.visibleOrder)
            #expect(host.projection.emptyMessage == host.state.emptyMessage)
        }
    }

    @Test
    func coarseDropClearsCachesAndNextCommitFiresConservatively() {
        let host = StubHost(ProfileState(modal: DetailState(title: "same")))
        let modalKey = root.appending(\ProfileState._ViewMembers.modal)
        let displayKey = modalKey.appending(\DetailState._ViewMembers.display)

        if let modal = host.projection.modal {  // bound child projection: granular reads
            #expect(modal.display == "same")  // seeds the cache
        }
        // Presence flip: coarse prefix fire covers shape + registered descendants and
        // clears cached outputs under the prefix.
        let dropPokes = host.commit { $0.modal = nil }
        #expect(dropPokes.contains(modalKey.structure))
        #expect(dropPokes.contains(displayKey))
        // Reappear with an identical derived output: the cache was cleared, so the next
        // commit recomputes, reseeds, and fires conservatively.
        let reappearPokes = host.commit { $0.modal = DetailState(title: "same") }
        #expect(reappearPokes.contains(displayKey))
        #expect(host.projection.modal?.display == "same")
    }

    // MARK: Batching / bubbling

    @Test
    func batchDedupePokesEachSignalOncePerCommit() {
        let host = StubHost(SearchState())
        registrarAccessRoot(host.registrar)
        _ = host.projection.query
        _ = host.projection.isLoading

        let pokes = host.commit {
            $0.query = "q"
            $0.isLoading = true
        }
        // Three registered signals (query, isLoading, root) — each poked exactly once.
        #expect(pokes.count == 3)
        #expect(Set(pokes).count == 3)
        #expect(pokes.contains(root))
    }

    @Test
    func rootSlotFiresIffCommitChangedSomethingVisible() {
        let host = StubHost(SearchState())
        registrarAccessRoot(host.registrar)

        // Visible change with the leaf itself unread: root still wakes by bubbling.
        #expect(host.commit { $0.query = "a" } == [root])
        // Domain-only change: root does not wake.
        #expect(host.commit { $0.rawResults = [SearchResult(id: 1, name: "n")] }.isEmpty)
        // No change at all: nothing.
        #expect(host.commit { _ in }.isEmpty)
    }

    @Test
    func boundChildProjectionsRegisterLeafAndShapeKeysOnly() {
        let host = StubHost(ProfileState(modal: DetailState()))
        let detail: FeatureProjection<DetailState> = host.projection.detail
        _ = detail.title  // leaf under a nested child
        if let modal = host.projection.modal {  // shape key, then leaf under the child
            _ = modal.title
        }

        // A sibling member under the same children changes: had chaining registered the
        // interior keys, they would be poked by bubbling — nothing may fire.
        let pokes = host.commit {
            $0.detail.subtitleText = "x"
            $0.modal?.subtitleText = "y"
        }
        #expect(pokes.isEmpty)
    }

    @Test
    func inlineChainedReadRegistersCoarseSubtreeKey() {
        let host = StubHost(ProfileState())
        let detailKey = root.appending(\ProfileState._ViewMembers.detail)
        // An inline chain resolves through the leaf subscript: the read registers the
        // child's interior subtree key — coarse but correct.
        _ = host.projection.detail.title

        // Any visible change under the child bubbles to the interior key.
        let pokes = host.commit { $0.detail.subtitleText = "x" }
        #expect(pokes == [detailKey])
        // A change elsewhere does not reach it.
        #expect(host.commit { $0.name = "n" }.isEmpty)
    }

    // MARK: Nesting / optionals

    @Test
    func nestedDelegationFiresChildMemberKey() {
        let host = StubHost(ProfileState())
        let titleKey = root
            .appending(\ProfileState._ViewMembers.detail)
            .appending(\DetailState._ViewMembers.title)
        let detail: FeatureProjection<DetailState> = host.projection.detail
        _ = detail.title
        #expect(host.commit { $0.detail.title = "n" } == [titleKey])
    }

    @Test
    func optionalPresenceFlipFiresPrefix() {
        let host = StubHost(ProfileState())
        let modalKey = root.appending(\ProfileState._ViewMembers.modal)
        #expect(host.projection.modal == nil)  // registers the shape key

        // nil → some: prefix fire covers the shape key.
        #expect(host.commit { $0.modal = DetailState(title: "t") } == [modalKey.structure])
        let modal = host.projection.modal  // bound child projection: granular reads
        #expect(modal?.title == "t")
        // Content change while present: shape key does not fire.
        let contentPokes = host.commit { $0.modal?.title = "u" }
        #expect(!contentPokes.contains(modalKey.structure))
        #expect(contentPokes.contains(modalKey.appending(\DetailState._ViewMembers.title)))
        // some → nil: prefix fire again.
        #expect(host.commit { $0.modal = nil }.contains(modalKey.structure))
    }

    // MARK: Enums

    @Test
    func enumSameCaseDiffsGranularly() {
        let host = StubHost(RouteState.detail(DetailState(title: "a")))
        let detailKey = root.appending(\RouteState._ViewMembers.detail)
        let titleKey = detailKey.appending(\DetailState._ViewMembers.title)
        if let detail = host.projection.detail {  // bound child projection
            _ = detail.title
        }
        _ = host.projection.accessibilityLabel

        let pokes = host.commit { $0 = .detail(DetailState(title: "b")) }
        #expect(pokes.contains(titleKey))
        #expect(!pokes.contains(detailKey.structure))  // same case: presence did not flip
        #expect(!pokes.contains(root.appending(\RouteState._ViewMembers.accessibilityLabel)))
    }

    @Test
    func enumCaseFlipFiresCoarsely() {
        let host = StubHost(RouteState.detail(DetailState(title: "a")))
        let detailKey = root.appending(\RouteState._ViewMembers.detail)
        let labelKey = root.appending(\RouteState._ViewMembers.accessibilityLabel)
        if let detail = host.projection.detail {  // shape + leaf
            _ = detail.title
        }
        _ = host.projection.accessibilityLabel

        let pokes = host.commit { $0 = .banner("hello") }
        // Coarse: every registered signal under the (root) prefix fires.
        #expect(pokes.contains(detailKey.structure))
        #expect(pokes.contains(detailKey.appending(\DetailState._ViewMembers.title)))
        #expect(pokes.contains(labelKey))
        #expect(host.projection.detail == nil)
        #expect(host.projection.banner == "hello")
        #expect(host.projection.accessibilityLabel == "hello")
    }

    @Test
    func enumSameCaseLeafPayloadDiffsAsLeaf() {
        let host = StubHost(RouteState.banner("a"))
        let bannerKey = root.appending(\RouteState._ViewMembers.banner)
        _ = host.projection.banner

        #expect(host.commit { $0 = .banner("b") } == [bannerKey])
        #expect(host.commit { $0 = .banner("b") }.isEmpty)
    }

    // MARK: Collections (spec §6.1 table)

    @Test
    func collectionStructuralChangePingsShapeKeyAndPrunesDepartedSignals() {
        FixtureCounters.reset()
        let host = StubHost(
            TransactionsState(transactions: [
                Transaction(id: 1, merchantName: "A"),
                Transaction(id: 2, merchantName: "B"),
            ])
        )
        let collectionKey = root.appending(\TransactionsState._ViewMembers.transactions)
        let row = host.projection.transactions[id: 1]  // bound row projection
        #expect(row?.title == "A")  // seeds element cache

        let pokes = host.commit { $0.transactions.remove(id: 1) }
        #expect(pokes.contains(collectionKey.structure))

        // Pruned: if id 1 returns with different content, reads must not serve the stale
        // cached output.
        host.commit { $0.transactions.insert(Transaction(id: 1, merchantName: "A2"), at: 0) }
        let rowAfter = host.projection.transactions[id: 1]
        #expect(rowAfter?.title == "A2")
    }

    @Test
    func collectionReorderPingsShapeKeyOnly() {
        let host = StubHost(
            TransactionsState(transactions: [
                Transaction(id: 1, merchantName: "A"),
                Transaction(id: 2, merchantName: "B"),
            ])
        )
        let collectionKey = root.appending(\TransactionsState._ViewMembers.transactions)
        _ = host.projection.transactions.ids  // registers the shape key
        _ = host.projection.transactions[id: 1]?.title  // per-element leaf

        let pokes = host.commit { $0.transactions.swapAt(0, 1) }
        #expect(pokes == [collectionKey.structure])
    }

    @Test
    func collectionUnchangedElementsAreSkippedEntirely() {
        FixtureCounters.reset()
        let host = StubHost(
            TransactionsState(transactions: [
                Transaction(id: 1, merchantName: "A"),
                Transaction(id: 2, merchantName: "B"),
            ])
        )
        _ = host.projection.transactions[id: 1]?.icon
        let baseline = FixtureCounters.count("Transaction.icon")

        // A domain-only parent change: every element compares equal — no element _commit,
        // no derivation, no fires.
        let pokes = host.commit { $0.account = Account(name: "new") }
        #expect(pokes.isEmpty)
        #expect(FixtureCounters.count("Transaction.icon") == baseline)
    }

    @Test
    func collectionChangedElementFiresOnlyItsChangedMemberKeys() {
        let host = StubHost(
            TransactionsState(transactions: [
                Transaction(id: 1, amount: 5, merchantName: "A"),
                Transaction(id: 2, amount: 6, merchantName: "B"),
            ])
        )
        let collectionKey = root.appending(\TransactionsState._ViewMembers.transactions)
        let elementKey = collectionKey.appending(id: 1)
        // Observe all four derived members of element 1 (and one of element 2).
        let row = host.projection.transactions[id: 1]!
        _ = row.title
        _ = row.amountLabel
        _ = row.icon
        _ = row.isFlagged
        _ = host.projection.transactions[id: 2]?.icon

        // §6.3 trace: flag element 1. `title`/`amountLabel` outputs are unchanged (no
        // fire); `icon`/`isFlagged` change (fire); element 2 is skipped.
        let pokes = host.commit { $0.transactions[id: 1]?.flagged = true }
        #expect(
            Set(pokes) == [
                elementKey.appending(\Transaction._ViewMembers.icon),
                elementKey.appending(\Transaction._ViewMembers.isFlagged),
            ]
        )
    }

    @Test
    func removedElementProjectionReturnsNil() {
        let host = StubHost(
            TransactionsState(transactions: [Transaction(id: 1, merchantName: "A")])
        )
        host.commit { $0.transactions.remove(id: 1) }
        #expect(host.projection.transactions[id: 1] == nil)
        #expect(host.projection.transactions.isEmpty)
        #expect(host.projection.transactions.count == 0)
    }

    // MARK: Key-path map round-trips (risk §13: `_viewKeyPaths` casts hold per member kind)

    @Test
    func keyPathRoundTripsForEveryMemberKind() {
        let search = StubHost(
            SearchState(
                rawResults: [SearchResult(id: 1, name: "n")], query: "q", isLoading: true))
        #expect(search.projection.query == "q")
        #expect(search.projection.isLoading == true)
        #expect(search.projection.subtitle == "1 results")

        let profile = StubHost(
            ProfileState(
                name: "p",
                detail: DetailState(badge: 1, title: "d"),
                modal: DetailState(title: "m")))
        #expect(profile.projection.name == "p")
        #expect(profile.projection.detail.title == "d")
        #expect(profile.projection.detail.display == "d (1)")
        #expect(profile.projection.modal?.title == "m")

        let route = StubHost(RouteState.detail(DetailState(title: "d")))
        #expect(route.projection.detail?.title == "d")
        #expect(route.projection.banner == nil)
        #expect(route.projection.accessibilityLabel == "Item detail")

        let transactions = StubHost(
            TransactionsState(transactions: [
                Transaction(id: 1, amount: 3, merchantName: "A", postedAt: 2)
            ])
        )
        #expect(transactions.projection.transactions.ids == [1])
        #expect(transactions.projection.visibleOrder == [1])
        #expect(transactions.projection.emptyMessage == nil)
        #expect(transactions.projection.transactions[id: 1]?.amountLabel == "$3")
    }
}

/// Registers a whole-state observation on the root slot.
@MainActor
private func registrarAccessRoot(_ registrar: FeatureStateRegistrar) {
    registrar.access(ProjectionKey())
}

/// Deterministic seeded RNG for the randomized mutation-sequence gate.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
