import CasePaths
import Foundation
import IdentifiedCollections
import Observation
import SwiftUI
import Testing

@testable import Lattice

@FeatureState private struct BadgeLabelState: Equatable, Sendable {
    var text = "new"
}

@FeatureState private struct BadgeState: Equatable, Sendable {
    var count: Int
    var label = BadgeLabelState()
}

@FeatureState private struct HeaderState: Equatable, Sendable {
    var title: String
    var badge: BadgeState
    @Domain var refreshCount = 0
    var refreshText: String { refreshCount == 0 ? "Never refreshed" : "Refreshed \(refreshCount)x" }
}

@FeatureState private struct RowState: Equatable, Identifiable, Sendable {
    let id: Int
    var title: String
    var count = 0

    mutating func apply(_ action: RowAction) {
        switch action {
        case .titleChanged(let title): self.title = title
        case .incremented: count += 1
        }
    }
}

@FeatureState private struct ListState: Equatable, Sendable {
    var rows: [RowState] = [RowState(id: 1, title: "one"), RowState(id: 2, title: "two")]
    var idRows: IdentifiedArrayOf<RowState> = [RowState(id: 1, title: "one"), RowState(id: 2, title: "two")]
    var selection: RowState?
}

@FeatureState private struct AppState: Equatable, Sendable {
    var header = HeaderState(title: "h", badge: BadgeState(count: 0))
    var footer = "f"
    var detail: HeaderState?
    var list = ListState()
}

@CasePathable private enum BadgeLabelAction: Sendable {
    case textChanged(String)
}

@CasePathable private enum BadgeAction: Sendable {
    case incremented
    case label(BadgeLabelAction)
}

@CasePathable private enum HeaderAction: Sendable {
    case titleChanged(String)
    case badge(BadgeAction)
    case refreshTapped
    case rebuilt(String)  // replaces the header wholesale
}

@CasePathable private enum RowAction: Sendable {
    case titleChanged(String)
    case incremented
}

@CasePathable private enum ListAction: Sendable {
    case row(RowState.ID, RowAction)
    case idRow(RowState.ID, RowAction)
    case selection(RowAction)
    case select(RowState.ID?)
    case insertAtFront
    case remove(RowState.ID)
}

@CasePathable private enum AppAction: Sendable {
    case header(HeaderAction)
    case detail(HeaderAction)
    case list(ListAction)
    case setFooter(String)
    case showDetail
    case hideDetail
}

@Interactor<HeaderState, HeaderAction>
private struct HeaderInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action, effects in
            switch action {
            case .titleChanged(let title): state.title = title
            case .badge(.incremented): state.badge.count += 1
            case .badge(.label(.textChanged(let text))): state.badge.label.text = text
            case .refreshTapped:
                state.refreshCount += 1
                // Async effect: exercises the effect task's propagation through the scope. It
                // suspends first, so only the returned task covers its follow-up action.
                effects.perform {
                    await Task.yield()
                    try effects.send(.badge(.incremented))
                }
            case .rebuilt(let title):
                state = HeaderState(title: title, badge: BadgeState(count: state.badge.count))
            }
        }
    }
}

@Interactor<ListState, ListAction>
private struct ListInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case .row(let id, let action):
                guard let index = state.rows.firstIndex(where: { $0.id == id }) else { break }
                state.rows[index].apply(action)
            case .idRow(let id, let action):
                state.idRows[id: id]?.apply(action)
            case .selection(let action):
                state.selection?.apply(action)
            case .select(let id):
                state.selection = id.flatMap { id in state.rows.first { $0.id == id } }
            case .insertAtFront:
                state.rows.insert(RowState(id: 0, title: "zero"), at: 0)
                state.idRows.insert(RowState(id: 0, title: "zero"), at: 0)
            case .remove(let id):
                state.rows.removeAll { $0.id == id }
                state.idRows.remove(id: id)
            }
        }
    }
}

@Interactor<AppState, AppAction>
private struct AppInteractor: Sendable {
    var body: some InteractorOf<Self> {
        Interactors.When(state: \.header, action: \.header) {
            HeaderInteractor()
        }
        Interactors.When(state: \.list, action: \.list) {
            ListInteractor()
        }
        Interact { state, action in
            switch action {
            case .detail(.titleChanged(let title)): state.detail?.title = title
            case .setFooter(let footer): state.footer = footer
            case .showDetail: state.detail = HeaderState(title: "d", badge: BadgeState(count: 0))
            case .hideDetail: state.detail = nil
            case .header, .detail, .list: break
            }
        }
    }
}

private func identifiers<Element: Identifiable>(of elements: [Element]) -> [Element.ID] {
    elements.map(\.id)
}

@MainActor
@Suite struct ScopedViewModelTests {
    private func makeViewModel() -> ViewModel<Feature<AppAction, AppState>> {
        ViewModel(initialState: AppState(), feature: Feature(interactor: AppInteractor()))
    }

    private func makeListViewModel() -> ViewModel<Feature<ListAction, ListState>> {
        ViewModel(initialState: ListState(), feature: Feature(interactor: ListInteractor()))
    }

    // MARK: Child

    @Test func scopedReadReflectsParentState() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        #expect(header.title == "h")
        #expect(header.badge.count == 0)
    }

    @Test func scopedSendEmbedsIntoParentAction() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        header.sendViewEvent(.titleChanged("new"))
        #expect(vm.viewState.header.title == "new")
    }

    @Test func scopedSendReturnsParentTaskForEffects() async {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        // .refreshTapped performs an effect in the parent's runtime; the returned task is the
        // parent's task for that effect, so awaiting it awaits the effect's follow-up action.
        await header.sendViewEvent(.refreshTapped)?.value
        #expect(vm.viewState.header.badge.count == 1)
    }

    @Test func scopedComputedMemberReadsDomainMember() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let refreshText = ObservationProbe { _ = header.refreshText }

        header.sendViewEvent(.refreshTapped)
        #expect(refreshText.didFire)
        #expect(header.refreshText == "Refreshed 1x")
    }

    @Test func scopedReadIsFineGrained_unrelatedSliceDoesNotInvalidate() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let title = ObservationProbe { _ = header.title }

        vm.sendViewEvent(.setFooter("f2"))  // footer change
        #expect(!title.didFire)  // header scope not invalidated
    }

    @Test func scopedReadIsFineGrained_nestedChildChangeDoesNotInvalidate() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let title = ObservationProbe { _ = header.title }

        header.sendViewEvent(.badge(.incremented))  // in place, inside the header's own subtree
        #expect(!title.didFire)  // the child's sibling member is not invalidated
        #expect(header.badge.count == 1)
    }

    @Test func scopedReadInvalidatesOnSliceChange() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let title = ObservationProbe { _ = header.title }

        header.sendViewEvent(.titleChanged("new"))
        #expect(title.didFire)
    }

    @Test func wholeSliceReadIsCoarse_inPlaceLeafMutationDoesNotInvalidate() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let coarse = ObservationProbe { _ = header.viewState }

        header.sendViewEvent(.titleChanged("new"))  // in-place leaf mutation
        #expect(!coarse.didFire)  // the path to the header is unchanged
        #expect(header.title == "new")  // reads still see the live value
    }

    @Test func wholeSliceReadInvalidatesOnWholesaleReplacement() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let coarse = ObservationProbe { _ = header.viewState }

        header.sendViewEvent(.rebuilt("new"))  // the interactor rebuilds the header wholesale
        #expect(coarse.didFire)
        #expect(header.viewState.title == "new")
    }

    @Test func nestedScopeComposes() {
        let vm = makeViewModel()
        // App > header > badge: chained scope onto a nested @FeatureState child.
        let badge = vm.scope(state: \.header, action: \.header)
            .scope(state: \.badge, action: \.badge)
        #expect(badge.count == 0)
        badge.sendViewEvent(.incremented)
        #expect(vm.viewState.header.badge.count == 1)
    }

    @Test func threeLevelScopeChainSendsAndBindsThroughEveryHop() {
        let vm = makeViewModel()
        // App > header > badge > label: each hop embeds its action into the one above.
        let label = vm.scope(state: \.header, action: \.header)
            .scope(state: \.badge, action: \.badge)
            .scope(state: \.label, action: \.label)
        let binding = label.binding(\.text, sending: \.textChanged)
        #expect(binding.wrappedValue == "new")

        binding.wrappedValue = "typed"
        #expect(vm.viewState.header.badge.label.text == "typed")
        #expect(binding.wrappedValue == "typed")

        label.sendViewEvent(.textChanged("sent"))
        #expect(vm.viewState.header.badge.label.text == "sent")
    }

    @Test func readOnlyScopeHasNoActionSurface() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header)  // ScopedViewModel<HeaderState, Never>
        #expect(header.badge.count == 0)
    }

    @Test func readOnlyScopeReadInvalidatesOnSliceChange() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header)  // sends nothing, still observed
        let title = ObservationProbe { _ = header.title }

        vm.sendViewEvent(.header(.titleChanged("new")))
        #expect(title.didFire)
        #expect(header.title == "new")  // a live read, not the value at creation
    }

    @Test func bindingGetterIsFineGrainedAndSetterSends() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        let binding = header.binding(\.title, sending: \.titleChanged)
        #expect(binding.wrappedValue == "h")
        binding.wrappedValue = "typed"
        #expect(vm.viewState.header.title == "typed")
    }

    @Test func closureActionOverloadEmbedsWithoutCasePaths() {
        let vm = makeViewModel()
        // General form: map child action -> parent action with a closure.
        let header = vm.scope(state: \.header, action: { AppAction.header($0) })
        header.sendViewEvent(.titleChanged("closure"))
        #expect(vm.viewState.header.title == "closure")
    }

    @Test func sendViewEventActsAsTypedCallbackHandoff() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        // Wrap in a closure to hand off to a child view's (HeaderAction) -> Void callback.
        let handler: @MainActor (HeaderAction) -> Void = { header.sendViewEvent($0) }
        handler(.titleChanged("viaSend"))
        #expect(vm.viewState.header.title == "viaSend")
    }

    @Test func anyVoidChildBridgesAtCallSite() {
        let vm = makeViewModel()
        let header = vm.scope(state: \.header, action: \.header)
        // The consumer who chose (Any) -> Void owns the cast at the call site.
        let erasedChildCallback: (Any) -> Void = {
            if let a = $0 as? HeaderAction { header.sendViewEvent(a) }
        }

        erasedChildCallback(HeaderAction.titleChanged("viaAny"))
        #expect(vm.viewState.header.title == "viaAny")

        erasedChildCallback("not a HeaderAction")  // consumer's cast drops it
        #expect(vm.viewState.header.title == "viaAny")
    }

    // MARK: Optional child

    @Test func optionalChildScopeIsNilWhileAbsentAndLiveWhilePresent() throws {
        let vm = makeViewModel()
        #expect(vm.scope(state: \.detail, action: \.detail) == nil)

        vm.sendViewEvent(.showDetail)
        let detail = try #require(vm.scope(state: \.detail, action: \.detail))
        let title = ObservationProbe { _ = detail.title }

        detail.sendViewEvent(.titleChanged("dd"))
        #expect(title.didFire)
        #expect(detail.title == "dd")
        #expect(vm.detail?.title == "dd")
    }

    @Test func optionalChildScopeServesItsSnapshotAfterRemoval() throws {
        let vm = makeViewModel()
        vm.sendViewEvent(.showDetail)
        let detail = try #require(vm.scope(state: \.detail, action: \.detail))

        vm.sendViewEvent(.hideDetail)  // the scope is now stale
        #expect(detail.title == "d")  // creation snapshot, no trap/crash
    }

    // MARK: Collections

    @Test func arrayCollectionScopesReFindTheirElementByID() {
        let vm = makeListViewModel()
        let rows = vm.scope(state: \.rows, action: \.row)
        #expect(rows.map(\.id) == [1, 2])

        rows[1].sendViewEvent(.incremented)
        #expect(rows[1].count == 1)
        #expect(vm.rows[1].count == 1)

        vm.sendViewEvent(.insertAtFront)  // shifts positions; each scope follows its id
        #expect(rows[1].id == 2)
        #expect(rows[1].count == 1)
        rows[1].sendViewEvent(.titleChanged("deux"))
        #expect(vm.rows[2].title == "deux")
    }

    @Test func identifiedArrayCollectionScopesReFindTheirElementByID() {
        let vm = makeListViewModel()
        let rows = vm.scope(state: \.idRows, action: \.idRow)
        #expect(rows.map(\.id) == [1, 2])

        let second = ObservationProbe { _ = rows[1].title }
        let first = ObservationProbe { _ = rows[0].title }
        rows[1].sendViewEvent(.titleChanged("deux"))
        #expect(second.didFire)
        #expect(!first.didFire)

        vm.sendViewEvent(.insertAtFront)
        #expect(rows[1].title == "deux")
        #expect(vm.idRows[id: 2]?.title == "deux")
    }

    @Test func collectionScopesAreIdentifiableForForEach() {
        let vm = makeListViewModel()
        let rows = vm.scope(state: \.idRows, action: \.idRow)

        #expect(identifiers(of: rows) == [1, 2])
        _ = ForEach(rows) { row in Text(row.title) }
    }

    @Test func collectionScopeServesItsSnapshotAfterTheElementIsRemoved() {
        let vm = makeListViewModel()
        let arrayRows = vm.scope(state: \.rows, action: \.row)
        let identifiedRows = vm.scope(state: \.idRows, action: \.idRow)

        vm.sendViewEvent(.remove(1))
        #expect(vm.rows.map(\.id) == [2])
        #expect(arrayRows[0].title == "one")  // creation snapshot, no trap/crash
        #expect(identifiedRows[0].title == "one")
    }

    // MARK: Overloads on ScopedViewModel

    @Test func scopedViewModelScopesIntoCollectionsOptionalsAndClosures() throws {
        let vm = makeViewModel()
        let list = vm.scope(state: \.list, action: \.list)

        let rows = list.scope(state: \.rows, action: \.row)
        rows[0].sendViewEvent(.incremented)
        #expect(vm.list.rows[0].count == 1)

        let identifiedRows = list.scope(state: \.idRows, action: \.idRow)
        identifiedRows[1].sendViewEvent(.titleChanged("deux"))
        #expect(vm.list.idRows[id: 2]?.title == "deux")

        #expect(list.scope(state: \.selection, action: \.selection) == nil)
        list.sendViewEvent(.select(2))
        let selection = try #require(list.scope(state: \.selection, action: \.selection))
        selection.sendViewEvent(.incremented)
        #expect(vm.list.selection?.count == 1)

        let header = vm.scope(state: \.header, action: \.header)
        header.scope(state: \.badge, action: { HeaderAction.badge($0) }).sendViewEvent(.incremented)
        #expect(header.scope(state: \.badge).count == 1)
    }
}
