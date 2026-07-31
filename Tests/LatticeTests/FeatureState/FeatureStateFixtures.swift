// Phase A fixtures for the @FeatureState runtime (plan 05 §12 phase A): hand expansions of
// the spec §4 examples, wired to a stub host. Phase B replaces the hand-expanded members
// with the real `@FeatureState`/`@Domain` macros; `FeatureStateRuntimeTests.swift` is
// untouched by that swap.

import IdentifiedCollections

@testable import Lattice

// MARK: - Evaluation counters (observer-gating / single-compute assertions)

enum FixtureCounters {
    @MainActor static var counts: [String: Int] = [:]

    nonisolated static func increment(_ name: String) {
        MainActor.assumeIsolated { counts[name, default: 0] += 1 }
    }

    @MainActor static func count(_ name: String) -> Int { counts[name] ?? 0 }
    @MainActor static func reset() { counts = [:] }
}

// MARK: - Supporting plain types

struct SearchResult: Equatable {
    var id: Int
    var name: String
}

struct Account: Equatable {
    var name: String
}

struct TransactionFilter: Equatable {
    static let all = TransactionFilter(minAmount: 0)
    var minAmount: Int

    func includes(_ transaction: Transaction) -> Bool {
        transaction.amount >= minAmount
    }
}

// MARK: - SearchState (spec §4.1: representative struct)

struct SearchState {
    var rawResults: [SearchResult] = []  // @Domain (phase B): interactor-only
    var query: String = ""
    var isLoading: Bool = false
    var subtitle: String {
        "\(rawResults.count) results"
    }

    // -- hand expansion --

    struct _ViewMembers {
        let query: String
        let isLoading: Bool
        let subtitle: String
        @available(*, unavailable) private init() { fatalError() }
    }

    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
        \_ViewMembers.query: \SearchState.query,
        \_ViewMembers.isLoading: \SearchState.isLoading,
        \_ViewMembers.subtitle: \SearchState.subtitle,
    ]

    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
        \_ViewMembers.subtitle
    ]

    @MainActor static func _commit(
        old: SearchState, new: SearchState,
        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
    ) {
        Lattice._diff(
            old.query, new.query,
            registrar: registrar, key: key.appending(\_ViewMembers.query))
        Lattice._diff(
            old.isLoading, new.isLoading,
            registrar: registrar, key: key.appending(\_ViewMembers.isLoading))
        registrar.commitDerived(key.appending(\_ViewMembers.subtitle)) {
            new.subtitle
        }
    }
}

extension SearchState: Lattice.FeatureStateProtocol {}

// MARK: - DetailState (nested feature; counted derived member)

struct DetailState: Equatable {
    var badge: Int = 0  // @Domain (phase B)
    var title: String = ""
    var subtitleText: String = ""
    var display: String {
        FixtureCounters.increment("DetailState.display")
        return badge == 0 ? title : "\(title) (\(badge))"
    }

    // -- hand expansion --

    struct _ViewMembers {
        let title: String
        let subtitleText: String
        let display: String
        @available(*, unavailable) private init() { fatalError() }
    }

    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
        \_ViewMembers.title: \DetailState.title,
        \_ViewMembers.subtitleText: \DetailState.subtitleText,
        \_ViewMembers.display: \DetailState.display,
    ]

    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
        \_ViewMembers.display
    ]

    @MainActor static func _commit(
        old: DetailState, new: DetailState,
        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
    ) {
        Lattice._diff(
            old.title, new.title,
            registrar: registrar, key: key.appending(\_ViewMembers.title))
        Lattice._diff(
            old.subtitleText, new.subtitleText,
            registrar: registrar, key: key.appending(\_ViewMembers.subtitleText))
        registrar.commitDerived(key.appending(\_ViewMembers.display)) {
            new.display
        }
    }
}

extension DetailState: Lattice.FeatureStateProtocol {}

// MARK: - ProfileState (nesting + optional child parent)

struct ProfileState {
    var secret: Int = 0  // @Domain (phase B)
    var name: String = ""
    var detail: DetailState = DetailState()
    var modal: DetailState?

    // -- hand expansion --

    struct _ViewMembers {
        let name: String
        let detail: DetailState
        let modal: DetailState?
        @available(*, unavailable) private init() { fatalError() }
    }

    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
        \_ViewMembers.name: \ProfileState.name,
        \_ViewMembers.detail: \ProfileState.detail,
        \_ViewMembers.modal: \ProfileState.modal,
    ]

    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = []

    @MainActor static func _commit(
        old: ProfileState, new: ProfileState,
        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
    ) {
        Lattice._diff(
            old.name, new.name,
            registrar: registrar, key: key.appending(\_ViewMembers.name))
        Lattice._diff(
            old.detail, new.detail,
            registrar: registrar, key: key.appending(\_ViewMembers.detail))
        Lattice._diff(
            old.modal, new.modal,
            registrar: registrar, key: key.appending(\_ViewMembers.modal))
    }
}

extension ProfileState: Lattice.FeatureStateProtocol {}

// MARK: - RouteState (spec §4.2: enum)

enum RouteState {
    case list
    case detail(DetailState)
    case banner(String)

    var accessibilityLabel: String {
        switch self {
        case .list: "All items"
        case .detail: "Item detail"
        case .banner(let message): message
        }
    }

    // -- hand expansion --

    var detail: DetailState? {
        guard case .detail(let value) = self else { return nil }
        return value
    }

    var banner: String? {
        guard case .banner(let value) = self else { return nil }
        return value
    }

    struct _ViewMembers {
        let detail: DetailState?
        let banner: String?
        let accessibilityLabel: String
        @available(*, unavailable) private init() { fatalError() }
    }

    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
        \_ViewMembers.detail: \RouteState.detail,
        \_ViewMembers.banner: \RouteState.banner,
        \_ViewMembers.accessibilityLabel: \RouteState.accessibilityLabel,
    ]

    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
        \_ViewMembers.accessibilityLabel
    ]

    @MainActor static func _commit(
        old: RouteState, new: RouteState,
        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
    ) {
        switch (old, new) {
        case (.list, .list):
            break
        case (.detail(let oldValue), .detail(let newValue)):
            Lattice._diff(
                oldValue, newValue,
                registrar: registrar, key: key.appending(\_ViewMembers.detail))
        case (.banner(let oldValue), .banner(let newValue)):
            Lattice._diff(
                oldValue, newValue,
                registrar: registrar, key: key.appending(\_ViewMembers.banner))
        default:
            registrar.invalidate(prefix: key)
            return
        }
        registrar.commitDerived(key.appending(\_ViewMembers.accessibilityLabel)) {
            new.accessibilityLabel
        }
    }
}

extension RouteState: Lattice.FeatureStateProtocol {}

// MARK: - Transaction (spec §6.3: element-as-feature)

struct Transaction: Identifiable, Equatable {
    let id: Int
    var amount: Int = 0  // @Domain (phase B)
    var merchantName: String = ""  // @Domain (phase B)
    var flagged: Bool = false  // @Domain (phase B)
    var postedAt: Int = 0  // @Domain (phase B)

    var title: String {
        FixtureCounters.increment("Transaction.title")
        return merchantName
    }
    var amountLabel: String {
        FixtureCounters.increment("Transaction.amountLabel")
        return "$\(amount)"
    }
    var icon: String {
        FixtureCounters.increment("Transaction.icon")
        return flagged ? "flag" : "circle"
    }
    var isFlagged: Bool {
        FixtureCounters.increment("Transaction.isFlagged")
        return flagged
    }

    // -- hand expansion --

    struct _ViewMembers {
        let id: Int
        let title: String
        let amountLabel: String
        let icon: String
        let isFlagged: Bool
        @available(*, unavailable) private init() { fatalError() }
    }

    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
        \_ViewMembers.id: \Transaction.id,
        \_ViewMembers.title: \Transaction.title,
        \_ViewMembers.amountLabel: \Transaction.amountLabel,
        \_ViewMembers.icon: \Transaction.icon,
        \_ViewMembers.isFlagged: \Transaction.isFlagged,
    ]

    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
        \_ViewMembers.title,
        \_ViewMembers.amountLabel,
        \_ViewMembers.icon,
        \_ViewMembers.isFlagged,
    ]

    @MainActor static func _commit(
        old: Transaction, new: Transaction,
        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
    ) {
        Lattice._diff(
            old.id, new.id,
            registrar: registrar, key: key.appending(\_ViewMembers.id))
        registrar.commitDerived(key.appending(\_ViewMembers.title)) {
            new.title
        }
        registrar.commitDerived(key.appending(\_ViewMembers.amountLabel)) {
            new.amountLabel
        }
        registrar.commitDerived(key.appending(\_ViewMembers.icon)) {
            new.icon
        }
        registrar.commitDerived(key.appending(\_ViewMembers.isFlagged)) {
            new.isFlagged
        }
    }
}

extension Transaction: Lattice.FeatureStateProtocol {}

// MARK: - TransactionsState (spec §4.3: collection-bearing parent)

struct TransactionsState {
    var account: Account = Account(name: "")  // @Domain (phase B)
    var filter: TransactionFilter = .all  // @Domain (phase B)
    var transactions: IdentifiedArrayOf<Transaction> = []

    var visibleOrder: [Transaction.ID] {
        transactions.elements
            .filter(filter.includes)
            .sorted { $0.postedAt > $1.postedAt }
            .map(\.id)
    }

    var emptyMessage: String? {
        transactions.isEmpty ? "No transactions yet" : nil
    }

    // -- hand expansion --

    struct _ViewMembers {
        let transactions: IdentifiedArrayOf<Transaction>
        let visibleOrder: [Transaction.ID]
        let emptyMessage: String?
        @available(*, unavailable) private init() { fatalError() }
    }

    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
        \_ViewMembers.transactions: \TransactionsState.transactions,
        \_ViewMembers.visibleOrder: \TransactionsState.visibleOrder,
        \_ViewMembers.emptyMessage: \TransactionsState.emptyMessage,
    ]

    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
        \_ViewMembers.visibleOrder,
        \_ViewMembers.emptyMessage,
    ]

    @MainActor static func _commit(
        old: TransactionsState, new: TransactionsState,
        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
    ) {
        Lattice._diff(
            old.transactions, new.transactions,
            registrar: registrar, key: key.appending(\_ViewMembers.transactions))
        registrar.commitDerived(key.appending(\_ViewMembers.visibleOrder)) {
            new.visibleOrder
        }
        registrar.commitDerived(key.appending(\_ViewMembers.emptyMessage)) {
            new.emptyMessage
        }
    }
}

extension TransactionsState: Lattice.FeatureStateProtocol {}
