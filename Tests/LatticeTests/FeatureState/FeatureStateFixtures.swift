import Foundation
import CasePaths
import Lattice
import os

/// OSAllocatedUnfairLock owns every mutable probe access, including callbacks
/// invoked by mutations of independent state copies on background executors.
final class MutationProbe: Sendable, Equatable {
    private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())
    private let entries = OSAllocatedUnfairLock(initialState: [String]())
    func increment(_ key: String = "changes") { counts.withLock { $0[key, default: 0] += 1 } }
    func count(_ key: String = "changes") -> Int { counts.withLock { $0[key, default: 0] } }
    func append(_ value: String) { entries.withLock { $0.append(value) } }
    var log: [String] { entries.withLock { $0 } }
    static func == (lhs: MutationProbe, rhs: MutationProbe) -> Bool { lhs === rhs }
}

@FeatureState
struct MutationDetail: Sendable, Equatable {
    var title: String = "Detail"
    var sibling: Int = 0
    @Domain var secret: Int = 0
    var label: String { "\(title):\(secret)" }
}

@FeatureState
struct MutationRow: Sendable, Equatable, Identifiable {
    let id: Int
    var title: String
    var sibling: Int = 0
    var detail: MutationDetail = MutationDetail()
    @Domain var eligible: Bool = true
    @Domain var probe: MutationProbe = MutationProbe()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.probe.increment("rowEquality")
        return lhs.id == rhs.id && lhs.title == rhs.title && lhs.sibling == rhs.sibling
            && lhs.detail == rhs.detail && lhs.eligible == rhs.eligible
    }
}

@FeatureState
struct MutationParent: Sendable, Equatable {
    var detail: MutationDetail = MutationDetail()
    @Domain var rows: [MutationRow] = [MutationRow(id: 3, title: "Nested")]
    var filteredRows: [MutationRow] { rows.filter(\.eligible).sorted { $0.title < $1.title } }
}

@FeatureState
struct MutationState: Sendable, Equatable {
    @Domain var count: Int = 0
    @Domain var alternateCount: Int = 10
    @Domain var useAlternate: Bool = false
    @Domain var noise: Int = 0
    @Domain var probe: MutationProbe = MutationProbe()
    @Domain var rows: [MutationRow] = [MutationRow(id: 1, title: "Milk"), MutationRow(id: 2, title: "Bread")]
    var query: String = ""
    var ticket: Int = 0
    var child: MutationDetail = MutationDetail()
    var parent: MutationParent? = MutationParent()
    var label: String {
        probe.increment("label")
        return "\((useAlternate ? alternateCount : count) / 2) items"
    }
    var filteredRows: [MutationRow] {
        probe.increment("rows")
        return rows.filter { $0.eligible && (query.isEmpty || $0.title.contains(query)) }
            .sorted { $0.title < $1.title }
    }
}

@FeatureState
struct MutationGeneric<Value: Sendable & Equatable>: Sendable, Equatable {
    var value: Value
    var optional: Value?
}

@CasePathable
indirect enum MutationAction: Sendable {
    case count(Int)
    case addZero
    case alternate(Int)
    case useAlternate(Bool)
    case noise
    case query(String)
    case ticket(Int)
    case pair(Int, Int)
    case child(MutationDetailAction)
    case parent(MutationDetailAction)
    case removeParentAfterEdit
    case restoreParent(MutationParent)
    case row(Int, MutationRowAction)
    case excludeAfterRename(Int, String)
    case replaceRows([MutationRow])
    case reset(MutationState)
    case emitted(MutationAction)
    case chain
}

@CasePathable
enum MutationDetailAction: Sendable {
    case title(String)
    case sibling
    case secret(Int)
}

enum MutationRowAction: Sendable {
    case title(String)
    case sibling
    case eligible(Bool)
    case remove
}

struct MutationInteractor: Interactor, Sendable {
    let probe: MutationProbe

    var body: some Interactor<MutationState, MutationAction> {
        Interact { state, action in
            probe.append("action")
            switch action {
            case .count(let value): state.count = value
            case .addZero: state.count += 0
            case .alternate(let value): state.alternateCount = value
            case .useAlternate(let value): state.useAlternate = value
            case .noise: state.noise += 1
            case .query(let value): state.query = value
            case .ticket(let value): state.ticket = value
            case .pair(let count, let ticket):
                state.count = count
                state.ticket = ticket
            case .child(let action): Self.detail(&state.child, action)
            case .parent(let action):
                probe.increment("parentActions")
                if state.parent != nil { Self.detail(&state.parent!.detail, action) }
            case .removeParentAfterEdit:
                state.parent?.detail.title = "Transient"
                state.parent = nil
            case .restoreParent(let parent): state.parent = parent
            case .row(let id, let action):
                guard let index = state.rows.firstIndex(where: { $0.id == id }) else { return .none }
                switch action {
                case .title(let title): state.rows[index].title = title
                case .sibling: state.rows[index].sibling += 1
                case .eligible(let value): state.rows[index].eligible = value
                case .remove: state.rows.remove(at: index)
                }
            case .excludeAfterRename(let id, let title):
                guard let index = state.rows.firstIndex(where: { $0.id == id }) else { return .none }
                state.rows[index].title = title
                state.rows[index].eligible = false
            case .replaceRows(let rows): state.rows = rows
            case .reset(let newState): state = newState
            case .emitted(let action): return .perform { action }
            case .chain: return .perform { .emitted(.count(22)) }
            }
            return .none
        }
    }

    private static func detail(_ state: inout MutationDetail, _ action: MutationDetailAction) {
        switch action {
        case .title(let title): state.title = title
        case .sibling: state.sibling += 1
        case .secret(let value): state.secret = value
        }
    }
}

typealias MutationModel = ViewModel<Feature<MutationAction, MutationState, _FeatureStatePresentation>>

@MainActor
func mutationModel(_ state: MutationState = MutationState()) -> MutationModel {
    ViewModel(initialDomainState: state, feature: Feature(
        interactor: MutationInteractor(probe: state.probe),
        areStatesEqual: { _, _ in state.probe.increment("rootEquality"); return true }
    ))
}
