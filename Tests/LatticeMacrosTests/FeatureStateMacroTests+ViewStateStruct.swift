#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import SwiftSyntaxMacroExpansion
    import SwiftSyntaxMacros
    import SwiftSyntaxMacrosTestSupport
    import XCTest

    extension FeatureStateMacroTests {
        func testViewState_Struct_EveryMemberKind() {
            assertMacro {
                """
                @FeatureState
                public struct CounterState: Equatable, Sendable {
                    public var title = "Counter"
                    @Domain public var lastUpdatedAt: Date?
                    @Domain var nonce = 0
                    public var badge = BadgeState()
                    public var detail: BadgeState?
                    public var rows: IdentifiedArrayOf<BadgeState> = []
                    public var tags: [String] = []
                    public var lastUpdatedText: String { lastUpdatedAt.map(Self.format) ?? "Never" }
                    private var scratch = 0
                }
                """
            } expansion: {
                #"""
                public struct CounterState: Equatable, Sendable {
                    public var title {
                        @storageRestrictions(initializes: _title)
                        init(initialValue) {
                            _title = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.title)
                            return _title
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.title, &_title, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.title, &_title)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.title, &_title, oldValue, _$isIdentityEqual)
                          }
                          yield &_title
                        }
                    }
                    public var lastUpdatedAt: Date? {
                        @storageRestrictions(initializes: _lastUpdatedAt)
                        init(initialValue) {
                            _lastUpdatedAt = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.lastUpdatedAt)
                            return _lastUpdatedAt
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.lastUpdatedAt, &_lastUpdatedAt, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.lastUpdatedAt, &_lastUpdatedAt)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.lastUpdatedAt, &_lastUpdatedAt, oldValue, _$isIdentityEqual)
                          }
                          yield &_lastUpdatedAt
                        }
                    }
                    var nonce {
                        @storageRestrictions(initializes: _nonce)
                        init(initialValue) {
                            _nonce = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.nonce)
                            return _nonce
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.nonce, &_nonce, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.nonce, &_nonce)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.nonce, &_nonce, oldValue, _$isIdentityEqual)
                          }
                          yield &_nonce
                        }
                    }
                    public var badge {
                        @storageRestrictions(initializes: _badge)
                        init(initialValue) {
                            _badge = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.badge)
                            return _badge
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.badge, &_badge, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.badge, &_badge)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.badge, &_badge, oldValue, _$isIdentityEqual)
                          }
                          yield &_badge
                        }
                    }
                    public var detail: BadgeState? {
                        @storageRestrictions(initializes: _detail)
                        init(initialValue) {
                            _detail = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.detail)
                            return _detail
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.detail, &_detail, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.detail, &_detail)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.detail, &_detail, oldValue, _$isIdentityEqual)
                          }
                          yield &_detail
                        }
                    }
                    public var rows: IdentifiedArrayOf<BadgeState> {
                        @storageRestrictions(initializes: _rows)
                        init(initialValue) {
                            _rows = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.rows)
                            return _rows
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.rows, &_rows, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.rows, &_rows)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.rows, &_rows, oldValue, _$isIdentityEqual)
                          }
                          yield &_rows
                        }
                    }
                    public var tags: [String] {
                        @storageRestrictions(initializes: _tags)
                        init(initialValue) {
                            _tags = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.tags)
                            return _tags
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.tags, &_tags, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.tags, &_tags)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.tags, &_tags, oldValue, _$isIdentityEqual)
                          }
                          yield &_tags
                        }
                    }
                    public var lastUpdatedText: String { lastUpdatedAt.map(Self.format) ?? "Never" }
                    private var scratch {
                        @storageRestrictions(initializes: _scratch)
                        init(initialValue) {
                            _scratch = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.scratch)
                            return _scratch
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.scratch, &_scratch, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.scratch, &_scratch)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.scratch, &_scratch, oldValue, _$isIdentityEqual)
                          }
                          yield &_scratch
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    public protocol _$ViewStateTypes {
                        associatedtype title
                        var _$title: title {
                            get
                        }
                        associatedtype nonce
                        var _$nonce: nonce {
                            get
                        }
                        associatedtype badge
                        var _$badge: badge {
                            get
                        }
                        associatedtype detail
                        var _$detail: detail {
                            get
                        }
                        associatedtype rows
                        var _$rows: rows {
                            get
                        }
                        associatedtype tags
                        var _$tags: tags {
                            get
                        }
                        associatedtype lastUpdatedText
                        var _$lastUpdatedText: lastUpdatedText {
                            get
                        }
                    }

                    public struct _$ViewStateWitness: _$ViewStateTypes {
                        public let _$title = Lattice._$project(Lattice._$placeholder(CounterState.self).title)
                        public let _$nonce = Lattice._$placeholder(CounterState.self).nonce
                        public let _$badge = Lattice._$project(Lattice._$placeholder(CounterState.self).badge)
                        public let _$detail = Lattice._$project(Lattice._$placeholder(CounterState.self).detail)
                        public let _$rows = Lattice._$project(Lattice._$placeholder(CounterState.self).rows)
                        public let _$tags = Lattice._$project(Lattice._$placeholder(CounterState.self).tags)
                        public let _$lastUpdatedText = Lattice._$project(Lattice._$placeholder(CounterState.self).lastUpdatedText)
                    }

                    @Lattice._IdentifiableIfPossible(CounterState.self)
                    @Lattice._EquatableIfPossible(CounterState.self)
                    public struct ViewState: Lattice.ViewStateProjection, Sendable {
                        @_spi(Lattice) public let _state: CounterState
                        public init(_ state: CounterState) {
                            self._state = state
                        }
                        public var title: _$ViewStateWitness.title {
                            Lattice._$project(_state.title)
                        }
                        public var badge: _$ViewStateWitness.badge {
                            Lattice._$project(_state.badge)
                        }
                        public var detail: _$ViewStateWitness.detail {
                            Lattice._$project(_state.detail)
                        }
                        public var rows: _$ViewStateWitness.rows {
                            Lattice._$project(_state.rows)
                        }
                        public var tags: _$ViewStateWitness.tags {
                            Lattice._$project(_state.tags)
                        }
                        public var lastUpdatedText: _$ViewStateWitness.lastUpdatedText {
                            Lattice._$project(_state.lastUpdatedText)
                        }
                        @available(*, unavailable, message: "'lastUpdatedAt' is @Domain state and is not visible to views")
                        public var lastUpdatedAt: Date? {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'nonce' is @Domain state and is not visible to views")
                        public var nonce: _$ViewStateWitness.nonce {
                            fatalError()
                        }
                    }
                }

                extension CounterState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_MemberVisibility() {
            // Multi-binding `let`s project per binding. (A multi-binding `var` is rejected by the
            // observation accessor macro, which supports a single variable per declaration.)
            assertMacro {
                """
                @propertyWrapper
                struct Boxed<T> {
                    var wrappedValue: T
                }

                @FeatureState
                struct VisibilityState {
                    let id: Int
                    let first = 0, second = 1
                    private(set) var readOnly = 2
                    fileprivate(set) var fileReadOnly = 3
                    @ObservationStateIgnored @Boxed var wrapped: Int
                    @ObservationStateIgnored var ignored = 4
                    var computed: Int { first + second }
                    private var hidden = 5
                    fileprivate var fileHidden = 6
                    static var staticValue = 7
                    static let staticConstant = 8
                    func method() {}
                    struct Nested {}
                }
                """
            } expansion: {
                #"""
                @propertyWrapper
                struct Boxed<T> {
                    var wrappedValue: T
                }
                struct VisibilityState {
                    let id: Int
                    let first = 0, second = 1
                    private(set) var readOnly {
                        @storageRestrictions(initializes: _readOnly)
                        init(initialValue) {
                            _readOnly = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.readOnly)
                            return _readOnly
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.readOnly, &_readOnly, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.readOnly, &_readOnly)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.readOnly, &_readOnly, oldValue, _$isIdentityEqual)
                          }
                          yield &_readOnly
                        }
                    }
                    fileprivate(set) var fileReadOnly {
                        @storageRestrictions(initializes: _fileReadOnly)
                        init(initialValue) {
                            _fileReadOnly = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.fileReadOnly)
                            return _fileReadOnly
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.fileReadOnly, &_fileReadOnly, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.fileReadOnly, &_fileReadOnly)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.fileReadOnly, &_fileReadOnly, oldValue, _$isIdentityEqual)
                          }
                          yield &_fileReadOnly
                        }
                    }
                    @Boxed var wrapped: Int
                    var ignored = 4
                    var computed: Int { first + second }
                    private var hidden {
                        @storageRestrictions(initializes: _hidden)
                        init(initialValue) {
                            _hidden = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.hidden)
                            return _hidden
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.hidden, &_hidden, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.hidden, &_hidden)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.hidden, &_hidden, oldValue, _$isIdentityEqual)
                          }
                          yield &_hidden
                        }
                    }
                    fileprivate var fileHidden {
                        @storageRestrictions(initializes: _fileHidden)
                        init(initialValue) {
                            _fileHidden = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.fileHidden)
                            return _fileHidden
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.fileHidden, &_fileHidden, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.fileHidden, &_fileHidden)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.fileHidden, &_fileHidden, oldValue, _$isIdentityEqual)
                          }
                          yield &_fileHidden
                        }
                    }
                    static var staticValue = 7
                    static let staticConstant = 8
                    func method() {}
                    struct Nested {}

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype id
                        var _$id: id {
                            get
                        }
                        associatedtype first
                        var _$first: first {
                            get
                        }
                        associatedtype second
                        var _$second: second {
                            get
                        }
                        associatedtype readOnly
                        var _$readOnly: readOnly {
                            get
                        }
                        associatedtype fileReadOnly
                        var _$fileReadOnly: fileReadOnly {
                            get
                        }
                        associatedtype wrapped
                        var _$wrapped: wrapped {
                            get
                        }
                        associatedtype ignored
                        var _$ignored: ignored {
                            get
                        }
                        associatedtype computed
                        var _$computed: computed {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$id = Lattice._$project(Lattice._$placeholder(VisibilityState.self).id)
                        let _$first = Lattice._$project(Lattice._$placeholder(VisibilityState.self).first)
                        let _$second = Lattice._$project(Lattice._$placeholder(VisibilityState.self).second)
                        let _$readOnly = Lattice._$project(Lattice._$placeholder(VisibilityState.self).readOnly)
                        let _$fileReadOnly = Lattice._$project(Lattice._$placeholder(VisibilityState.self).fileReadOnly)
                        let _$wrapped = Lattice._$project(Lattice._$placeholder(VisibilityState.self).wrapped)
                        let _$ignored = Lattice._$project(Lattice._$placeholder(VisibilityState.self).ignored)
                        let _$computed = Lattice._$project(Lattice._$placeholder(VisibilityState.self).computed)
                    }

                    @Lattice._IdentifiableIfPossible(VisibilityState.self)
                    @Lattice._EquatableIfPossible(VisibilityState.self)
                    struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: VisibilityState
                        init(_ state: VisibilityState) {
                            self._state = state
                        }
                        var id: _$ViewStateWitness.id {
                            Lattice._$project(_state.id)
                        }
                        var first: _$ViewStateWitness.first {
                            Lattice._$project(_state.first)
                        }
                        var second: _$ViewStateWitness.second {
                            Lattice._$project(_state.second)
                        }
                        var readOnly: _$ViewStateWitness.readOnly {
                            Lattice._$project(_state.readOnly)
                        }
                        var fileReadOnly: _$ViewStateWitness.fileReadOnly {
                            Lattice._$project(_state.fileReadOnly)
                        }
                        var wrapped: _$ViewStateWitness.wrapped {
                            Lattice._$project(_state.wrapped)
                        }
                        var ignored: _$ViewStateWitness.ignored {
                            Lattice._$project(_state.ignored)
                        }
                        var computed: _$ViewStateWitness.computed {
                            Lattice._$project(_state.computed)
                        }
                    }
                }

                extension VisibilityState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_DomainTypedAndInferred() {
            assertMacro {
                """
                @FeatureState
                struct SessionState {
                    @Domain var token: String?
                    @Domain var attempts = 0
                    @Lattice.Domain let createdAt: Date
                    @Domain var isExpired: Bool { token == nil }
                    var name = ""
                }
                """
            } expansion: {
                #"""
                struct SessionState {
                    var token: String? {
                        @storageRestrictions(initializes: _token)
                        init(initialValue) {
                            _token = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.token)
                            return _token
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.token, &_token, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.token, &_token)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.token, &_token, oldValue, _$isIdentityEqual)
                          }
                          yield &_token
                        }
                    }
                    var attempts {
                        @storageRestrictions(initializes: _attempts)
                        init(initialValue) {
                            _attempts = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.attempts)
                            return _attempts
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.attempts, &_attempts, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.attempts, &_attempts)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.attempts, &_attempts, oldValue, _$isIdentityEqual)
                          }
                          yield &_attempts
                        }
                    }
                    @Lattice.Domain let createdAt: Date
                    var isExpired: Bool { token == nil }
                    var name {
                        @storageRestrictions(initializes: _name)
                        init(initialValue) {
                            _name = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.name)
                            return _name
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.name, &_name, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.name, &_name)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.name, &_name, oldValue, _$isIdentityEqual)
                          }
                          yield &_name
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype attempts
                        var _$attempts: attempts {
                            get
                        }
                        associatedtype name
                        var _$name: name {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$attempts = Lattice._$placeholder(SessionState.self).attempts
                        let _$name = Lattice._$project(Lattice._$placeholder(SessionState.self).name)
                    }

                    @Lattice._IdentifiableIfPossible(SessionState.self)
                    @Lattice._EquatableIfPossible(SessionState.self)
                    struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: SessionState
                        init(_ state: SessionState) {
                            self._state = state
                        }
                        var name: _$ViewStateWitness.name {
                            Lattice._$project(_state.name)
                        }
                        @available(*, unavailable, message: "'token' is @Domain state and is not visible to views")
                        var token: String? {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'attempts' is @Domain state and is not visible to views")
                        var attempts: _$ViewStateWitness.attempts {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'createdAt' is @Domain state and is not visible to views")
                        var createdAt: Date {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'isExpired' is @Domain state and is not visible to views")
                        var isExpired: Bool {
                            fatalError()
                        }
                    }
                }

                extension SessionState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_IfConfig() {
            assertMacro {
                """
                @FeatureState
                struct DebugState {
                    var count = 0
                    #if DEBUG
                        var debugNote = "debug"
                        @Domain var debugSecret: Int = 0
                        @Domain var debugCounter = 0
                    #elseif TESTING
                        var testNote = "test"
                    #else
                        @Domain var releaseSecret: Int = 0
                    #endif
                    #if os(macOS)
                        private var macOnly = 0
                    #endif
                }
                """
            } expansion: {
                #"""
                struct DebugState {
                    var count {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.count)
                            return _count
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                          }
                          yield &_count
                        }
                    }
                    #if DEBUG
                        var debugNote = "debug"
                        var debugSecret: Int = 0
                        var debugCounter = 0
                    #elseif TESTING
                        var testNote = "test"
                    #else
                        var releaseSecret: Int = 0
                    #endif
                    #if os(macOS)
                        private var macOnly = 0
                    #endif

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype count
                        var _$count: count {
                            get
                        }
                        #if DEBUG
                        associatedtype debugNote
                        var _$debugNote: debugNote {
                            get
                        }
                        associatedtype debugCounter
                        var _$debugCounter: debugCounter {
                            get
                        }
                        #elseif TESTING
                        associatedtype testNote
                        var _$testNote: testNote {
                            get
                        }
                        #else
                        #endif
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$count = Lattice._$project(Lattice._$placeholder(DebugState.self).count)
                        #if DEBUG
                        let _$debugNote = Lattice._$project(Lattice._$placeholder(DebugState.self).debugNote)
                        let _$debugCounter = Lattice._$placeholder(DebugState.self).debugCounter
                        #elseif TESTING
                        let _$testNote = Lattice._$project(Lattice._$placeholder(DebugState.self).testNote)
                        #else
                        #endif
                    }

                    @Lattice._IdentifiableIfPossible(DebugState.self)
                    @Lattice._EquatableIfPossible(DebugState.self)
                    struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: DebugState
                        init(_ state: DebugState) {
                            self._state = state
                        }
                        var count: _$ViewStateWitness.count {
                            Lattice._$project(_state.count)
                        }
                        #if DEBUG
                        var debugNote: _$ViewStateWitness.debugNote {
                            Lattice._$project(_state.debugNote)
                        }
                        #elseif TESTING
                        var testNote: _$ViewStateWitness.testNote {
                            Lattice._$project(_state.testNote)
                        }
                        #else
                        #endif
                        #if DEBUG
                        @available(*, unavailable, message: "'debugSecret' is @Domain state and is not visible to views")
                        var debugSecret: Int {
                            fatalError()
                        }
                        @available(*, unavailable, message: "'debugCounter' is @Domain state and is not visible to views")
                        var debugCounter: _$ViewStateWitness.debugCounter {
                            fatalError()
                        }
                        #elseif TESTING
                        #else
                        @available(*, unavailable, message: "'releaseSecret' is @Domain state and is not visible to views")
                        var releaseSecret: Int {
                            fatalError()
                        }
                        #endif
                    }
                }

                extension DebugState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_SendableFollowsInheritanceClause() {
            assertMacro {
                """
                @FeatureState
                struct UncheckedState: @unchecked Sendable {
                    var count = 0
                }
                """
            } expansion: {
                #"""
                struct UncheckedState: @unchecked Sendable {
                    var count {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.count)
                            return _count
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                          }
                          yield &_count
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype count
                        var _$count: count {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$count = Lattice._$project(Lattice._$placeholder(UncheckedState.self).count)
                    }

                    @Lattice._IdentifiableIfPossible(UncheckedState.self)
                    @Lattice._EquatableIfPossible(UncheckedState.self)
                    struct ViewState: Lattice.ViewStateProjection, Sendable {
                        @_spi(Lattice) public let _state: UncheckedState
                        init(_ state: UncheckedState) {
                            self._state = state
                        }
                        var count: _$ViewStateWitness.count {
                            Lattice._$project(_state.count)
                        }
                    }
                }

                extension UncheckedState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
            assertMacro {
                """
                @FeatureState
                struct ComposedState: Equatable & Swift.Sendable {
                    var count = 0
                }
                """
            } expansion: {
                #"""
                struct ComposedState: Equatable & Swift.Sendable {
                    var count {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.count)
                            return _count
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                          }
                          yield &_count
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    protocol _$ViewStateTypes {
                        associatedtype count
                        var _$count: count {
                            get
                        }
                    }

                    struct _$ViewStateWitness: _$ViewStateTypes {
                        let _$count = Lattice._$project(Lattice._$placeholder(ComposedState.self).count)
                    }

                    @Lattice._IdentifiableIfPossible(ComposedState.self)
                    @Lattice._EquatableIfPossible(ComposedState.self)
                    struct ViewState: Lattice.ViewStateProjection, Sendable {
                        @_spi(Lattice) public let _state: ComposedState
                        init(_ state: ComposedState) {
                            self._state = state
                        }
                        var count: _$ViewStateWitness.count {
                            Lattice._$project(_state.count)
                        }
                    }
                }

                extension ComposedState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }

        func testViewState_Struct_FilePrivateState() {
            assertMacro {
                """
                @FeatureState
                private struct HiddenState: Equatable {
                    var count = 0
                    @Domain var secret = 1
                }
                """
            } expansion: {
                #"""
                private struct HiddenState: Equatable {
                    var count {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.count)
                            return _count
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.count, &_count, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.count, &_count)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.count, &_count, oldValue, _$isIdentityEqual)
                          }
                          yield &_count
                        }
                    }
                    var secret {
                        @storageRestrictions(initializes: _secret)
                        init(initialValue) {
                            _secret = initialValue
                        }
                        get {
                            _$observationRegistrar.access(self, keyPath: \.secret)
                            return _secret
                        }
                        set {
                            _$observationRegistrar.mutate(self, keyPath: \.secret, &_secret, newValue, _$isIdentityEqual, shouldNotifyObservers)
                        }
                        _modify {
                          let oldValue = _$observationRegistrar.willModify(self, keyPath: \.secret, &_secret)
                          defer {
                            _$observationRegistrar.didModify(self, keyPath: \.secret, &_secret, oldValue, _$isIdentityEqual)
                          }
                          yield &_secret
                        }
                    }

                    var _$observationRegistrar = Lattice.ObservationStateRegistrar()

                    public var _$id: Lattice.ObservableStateID {
                        _$observationRegistrar.id
                    }

                    public mutating func _$willModify() {
                        _$observationRegistrar._$willModify()
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu_>(_ lhs: __macro_local_6MemberfMu_, _ rhs: __macro_local_6MemberfMu_) -> Bool {
                        true
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu0_: Equatable>(_ lhs: __macro_local_6MemberfMu0_, _ rhs: __macro_local_6MemberfMu0_) -> Bool {
                        lhs != rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu1_: AnyObject>(_ lhs: __macro_local_6MemberfMu1_, _ rhs: __macro_local_6MemberfMu1_) -> Bool {
                        lhs !== rhs
                    }

                    private nonisolated func shouldNotifyObservers<__macro_local_6MemberfMu2_: Equatable & AnyObject>(_ lhs: __macro_local_6MemberfMu2_, _ rhs: __macro_local_6MemberfMu2_) -> Bool {
                        lhs != rhs
                    }

                    fileprivate protocol _$ViewStateTypes {
                        associatedtype count
                        var _$count: count {
                            get
                        }
                        associatedtype secret
                        var _$secret: secret {
                            get
                        }
                    }

                    fileprivate struct _$ViewStateWitness: _$ViewStateTypes {
                        fileprivate let _$count = Lattice._$project(Lattice._$placeholder(HiddenState.self).count)
                        fileprivate let _$secret = Lattice._$placeholder(HiddenState.self).secret
                    }

                    @Lattice._IdentifiableIfPossible(HiddenState.self)
                    @Lattice._EquatableIfPossible(HiddenState.self)
                    fileprivate struct ViewState: Lattice.ViewStateProjection {
                        @_spi(Lattice) public let _state: HiddenState
                        fileprivate init(_ state: HiddenState) {
                            self._state = state
                        }
                        fileprivate var count: _$ViewStateWitness.count {
                            Lattice._$project(_state.count)
                        }
                        @available(*, unavailable, message: "'secret' is @Domain state and is not visible to views")
                        fileprivate var secret: _$ViewStateWitness.secret {
                            fatalError()
                        }
                    }
                }

                extension HiddenState: Lattice.FeatureState, Observation.Observable {
                }
                """#
            }
        }
    }
#endif
