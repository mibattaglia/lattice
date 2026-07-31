// Phase B fixtures for the @FeatureState runtime (plan 05 §12 phase B): the spec §4
// examples annotated with the real `@FeatureState`/`@Domain` macros, replacing phase A's
// hand expansions. `FeatureStateRuntimeTests.swift` is untouched by this swap.

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

@FeatureState
struct SearchState {
    @Domain var rawResults: [SearchResult] = []
    var query: String = ""
    var isLoading: Bool = false
    var subtitle: String {
        "\(rawResults.count) results"
    }
}

// MARK: - DetailState (nested feature; counted derived member)

@FeatureState
struct DetailState: Equatable {
    @Domain var badge: Int = 0
    var title: String = ""
    var subtitleText: String = ""
    var display: String {
        FixtureCounters.increment("DetailState.display")
        return badge == 0 ? title : "\(title) (\(badge))"
    }
}

// MARK: - ProfileState (nesting + optional child parent)

@FeatureState
struct ProfileState {
    @Domain var secret: Int = 0
    var name: String = ""
    var detail: DetailState = DetailState()
    var modal: DetailState?
}

// MARK: - RouteState (spec §4.2: enum)

@FeatureState
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
}

// MARK: - Transaction (spec §6.3: element-as-feature)

@FeatureState
struct Transaction: Identifiable, Equatable {
    let id: Int
    @Domain var amount: Int = 0
    @Domain var merchantName: String = ""
    @Domain var flagged: Bool = false
    @Domain var postedAt: Int = 0

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
}

// MARK: - TransactionsState (spec §4.3: collection-bearing parent)

@FeatureState
struct TransactionsState {
    @Domain var account: Account = Account(name: "")
    @Domain var filter: TransactionFilter = .all
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
}
