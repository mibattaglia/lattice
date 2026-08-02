// Fixtures for the @FeatureState runtime tests: representative state shapes annotated
// with the real `@FeatureState`/`@Domain` macros.

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

// MARK: - SearchState (representative struct)

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

// MARK: - RouteState (enum)

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

// MARK: - Transaction (element-as-feature)

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

// MARK: - TransactionsState (collection-bearing parent)

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
