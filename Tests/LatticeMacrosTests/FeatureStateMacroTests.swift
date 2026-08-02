#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import XCTest

    /// Expansion baselines: one exact-match test per representative fixture shape, plus
    /// one test per implemented syntactic-diagnostic rule. (The `@FeatureState`-returning
    /// computed-member warning is not implementable with the attached-macro API and is
    /// deferred.)
    final class FeatureStateMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(
                macros: [FeatureStateMacro.self]
            ) {
                super.invokeTest()
            }
        }

        // MARK: Expansion baselines

        func testRepresentativeStruct() {
            assertMacro {
                """
                @FeatureState
                struct SearchState {
                    @Domain var rawResults: [SearchResult] = []
                    var query: String = ""
                    var isLoading: Bool = false
                    var subtitle: String {
                        "\\(rawResults.count) results"
                    }
                }
                """
            } expansion: {
                #"""
                struct SearchState {
                    @Domain var rawResults: [SearchResult] = []
                    var query: String = ""
                    var isLoading: Bool = false
                    var subtitle: String {
                        "\(rawResults.count) results"
                    }

                    struct _ViewMembers {
                        let query: String
                        let isLoading: Bool
                        let subtitle: String
                        @available(*, unavailable) private init() {
                            fatalError()
                        }
                    }

                    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
                        \_ViewMembers.query: \SearchState.query,
                        \_ViewMembers.isLoading: \SearchState.isLoading,
                        \_ViewMembers.subtitle: \SearchState.subtitle,
                    ]

                    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
                        \_ViewMembers.subtitle,
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

                extension SearchState: Lattice.FeatureStateProtocol {
                }
                """#
            }
        }

        func testEnum() {
            assertMacro {
                """
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
                """
            } expansion: {
                #"""
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

                    var detail: DetailState? {
                        guard case .detail(let value) = self else {
                            return nil
                        }
                        return value
                    }

                    var banner: String? {
                        guard case .banner(let value) = self else {
                            return nil
                        }
                        return value
                    }

                    struct _ViewMembers {
                        let detail: DetailState?
                        let banner: String?
                        let accessibilityLabel: String
                        @available(*, unavailable) private init() {
                            fatalError()
                        }
                    }

                    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
                        \_ViewMembers.detail: \RouteState.detail,
                        \_ViewMembers.banner: \RouteState.banner,
                        \_ViewMembers.accessibilityLabel: \RouteState.accessibilityLabel,
                    ]

                    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
                        \_ViewMembers.accessibilityLabel,
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

                extension RouteState: Lattice.FeatureStateProtocol {
                }
                """#
            }
        }

        func testCollectionBearingParent() {
            assertMacro {
                """
                @FeatureState
                struct TransactionsState {
                    @Domain var account: Account
                    @Domain var filter: TransactionFilter = .all
                    var transactions: IdentifiedArrayOf<Transaction> = []

                    var visibleOrder: [Transaction.ID] {
                        transactions.elements
                            .filter(filter.includes)
                            .sorted { $0.postedAt > $1.postedAt }
                            .map(\\.id)
                    }

                    var emptyMessage: String? {
                        transactions.isEmpty ? "No transactions yet" : nil
                    }
                }
                """
            } diagnostics: {
                #"""
                @FeatureState
                struct TransactionsState {
                    @Domain var account: Account
                    @Domain var filter: TransactionFilter = .all
                    var transactions: IdentifiedArrayOf<Transaction> = []

                    var visibleOrder: [Transaction.ID] {
                        ╰─ ⚠️ returns a collection: derived collections are rebuilt and compared as one leaf value whenever observed at commit — model elements as '@FeatureState' values in an 'IdentifiedArrayOf' stored member, return '[ID]'/section keys for structure, or accept the O(n) compare
                        transactions.elements
                            .filter(filter.includes)
                            .sorted { $0.postedAt > $1.postedAt }
                            .map(\.id)
                    }

                    var emptyMessage: String? {
                        transactions.isEmpty ? "No transactions yet" : nil
                    }
                }
                """#
            } expansion: {
                #"""
                struct TransactionsState {
                    @Domain var account: Account
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

                    struct _ViewMembers {
                        let transactions: IdentifiedArrayOf<Transaction>
                        let visibleOrder: [Transaction.ID]
                        let emptyMessage: String?
                        @available(*, unavailable) private init() {
                            fatalError()
                        }
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

                extension TransactionsState: Lattice.FeatureStateProtocol {
                }
                """#
            }
        }

        // MARK: Syntactic diagnostics

        func testDiagnostic_VisibleComputedCollectionReturn_EmitsWarning() {
            assertMacro {
                """
                @FeatureState
                struct RowsState {
                    var rows: [RowViewData] {
                        []
                    }
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct RowsState {
                    var rows: [RowViewData] {
                        ╰─ ⚠️ returns a collection: derived collections are rebuilt and compared as one leaf value whenever observed at commit — model elements as '@FeatureState' values in an 'IdentifiedArrayOf' stored member, return '[ID]'/section keys for structure, or accept the O(n) compare
                        []
                    }
                }
                """
            } expansion: {
                #"""
                struct RowsState {
                    var rows: [RowViewData] {
                        []
                    }

                    struct _ViewMembers {
                        let rows: [RowViewData]
                        @available(*, unavailable) private init() {
                            fatalError()
                        }
                    }

                    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
                        \_ViewMembers.rows: \RowsState.rows,
                    ]

                    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
                        \_ViewMembers.rows,
                    ]

                    @MainActor static func _commit(
                        old: RowsState, new: RowsState,
                        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
                    ) {
                        registrar.commitDerived(key.appending(\_ViewMembers.rows)) {
                            new.rows
                        }
                    }
                }

                extension RowsState: Lattice.FeatureStateProtocol {
                }
                """#
            }
        }

        func testDiagnostic_CyclicDerivedProperties_EmitsWarning() {
            assertMacro {
                """
                @FeatureState
                struct CycleState {
                    var a: Int {
                        b + 1
                    }
                    var b: Int {
                        a + 1
                    }
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct CycleState {
                    var a: Int {
                        ╰─ ⚠️ cyclic derived properties will recurse at evaluation; break the cycle or mark one '@Domain'
                        b + 1
                    }
                    var b: Int {
                        ╰─ ⚠️ cyclic derived properties will recurse at evaluation; break the cycle or mark one '@Domain'
                        a + 1
                    }
                }
                """
            } expansion: {
                #"""
                struct CycleState {
                    var a: Int {
                        b + 1
                    }
                    var b: Int {
                        a + 1
                    }

                    struct _ViewMembers {
                        let a: Int
                        let b: Int
                        @available(*, unavailable) private init() {
                            fatalError()
                        }
                    }

                    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
                        \_ViewMembers.a: \CycleState.a,
                        \_ViewMembers.b: \CycleState.b,
                    ]

                    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = [
                        \_ViewMembers.a,
                        \_ViewMembers.b,
                    ]

                    @MainActor static func _commit(
                        old: CycleState, new: CycleState,
                        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
                    ) {
                        registrar.commitDerived(key.appending(\_ViewMembers.a)) {
                            new.a
                        }
                        registrar.commitDerived(key.appending(\_ViewMembers.b)) {
                            new.b
                        }
                    }
                }

                extension CycleState: Lattice.FeatureStateProtocol {
                }
                """#
            }
        }

        func testDiagnostic_VisibleComputedWithSetter_EmitsError() {
            assertMacro {
                """
                @FeatureState
                struct SettableState {
                    var stored: Int = 0
                    var proxy: Int {
                        get { stored }
                        set { stored = newValue }
                    }
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct SettableState {
                    var stored: Int = 0
                    var proxy: Int {
                        ╰─ 🛑 view-visible computed properties are get-only; add '@Domain' for interactor-side settable helpers
                        get { stored }
                        set { stored = newValue }
                    }
                }
                """
            }
        }

        func testDiagnostic_DomainOnPrivateMember_EmitsWarning() {
            assertMacro(["FeatureState": FeatureStateMacro.self, "Domain": DomainMacro.self]) {
                """
                @FeatureState
                struct RedundantState {
                    @Domain private var helper: Int = 0
                    var title: String = ""
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct RedundantState {
                    @Domain private var helper: Int = 0
                    ┬──────
                    ╰─ ⚠️ '@Domain' is redundant on a private member; 'private' already excludes it from the view surface
                    var title: String = ""
                }
                """
            } expansion: {
                #"""
                struct RedundantState {
                    private var helper: Int = 0
                    var title: String = ""

                    struct _ViewMembers {
                        let title: String
                        @available(*, unavailable) private init() {
                            fatalError()
                        }
                    }

                    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [
                        \_ViewMembers.title: \RedundantState.title,
                    ]

                    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = []

                    @MainActor static func _commit(
                        old: RedundantState, new: RedundantState,
                        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
                    ) {
                        Lattice._diff(
                            old.title, new.title,
                            registrar: registrar, key: key.appending(\_ViewMembers.title))
                    }
                }

                extension RedundantState: Lattice.FeatureStateProtocol {
                }
                """#
            }
        }

        func testDiagnostic_AttachedToClass_EmitsError() {
            assertMacro {
                """
                @FeatureState
                final class Model {
                    var title: String = ""
                }
                """
            } diagnostics: {
                """
                @FeatureState
                 ┬───────────
                 ╰─ 🛑 '@FeatureState' can only be attached to structs and enums
                final class Model {
                    var title: String = ""
                }
                """
            }
        }

        func testDiagnostic_MultiPayloadCase_EmitsError() {
            assertMacro {
                """
                @FeatureState
                enum Route {
                    case list
                    case detail(id: Int, title: String)
                }
                """
            } diagnostics: {
                """
                @FeatureState
                enum Route {
                    case list
                    case detail(id: Int, title: String)
                         ┬─────────────────────────────
                         ╰─ 🛑 enum cases with multiple associated values are not projected; wrap the payload in a single struct (annotate it '@FeatureState' for granular observation)
                }
                """
            }
        }

        func testDiagnostic_CaseAccessorCollision_EmitsError() {
            assertMacro {
                """
                @FeatureState
                enum Route {
                    case detail(DetailState)

                    var detail: String {
                        "detail"
                    }
                }
                """
            } diagnostics: {
                """
                @FeatureState
                enum Route {
                    case detail(DetailState)
                         ┬──────────────────
                         ╰─ 🛑 enum case 'detail' collides with an existing member, blocking its case accessor; rename the case or the member

                    var detail: String {
                        "detail"
                    }
                }
                """
            }
        }

        func testDiagnostic_VisibleMemberWithoutTypeAnnotation_EmitsError() {
            assertMacro {
                """
                @FeatureState
                struct InferredState {
                    var query = ""
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct InferredState {
                    var query = ""
                        ┬─────────
                        ╰─ 🛑 view-visible members need an explicit type annotation for the generated projection; add one, mark the member '@Domain', or make it 'private'
                }
                """
            }
        }

        func testDiagnostic_ZeroVisibleMembers_EmitsWarning() {
            assertMacro {
                """
                @FeatureState
                struct HiddenState {
                    @Domain var a: Int = 0
                    private var b: Int = 0
                }
                """
            } diagnostics: {
                """
                @FeatureState
                struct HiddenState {
                       ┬──────────
                       ╰─ ⚠️ every member is '@Domain' or private, so the type has no view surface; remove '@FeatureState' or expose a member
                    @Domain var a: Int = 0
                    private var b: Int = 0
                }
                """
            } expansion: {
                """
                struct HiddenState {
                    @Domain var a: Int = 0
                    private var b: Int = 0

                    struct _ViewMembers {
                        @available(*, unavailable) private init() {
                            fatalError()
                        }
                    }

                    @MainActor static let _viewKeyPaths: [PartialKeyPath<_ViewMembers>: AnyKeyPath] = [:]

                    @MainActor static let _derivedMembers: Set<PartialKeyPath<_ViewMembers>> = []

                    @MainActor static func _commit(
                        old: HiddenState, new: HiddenState,
                        registrar: Lattice.FeatureStateRegistrar, key: Lattice.ProjectionKey
                    ) {

                    }
                }

                extension HiddenState: Lattice.FeatureStateProtocol {
                }
                """
            }
        }
    }
#endif
