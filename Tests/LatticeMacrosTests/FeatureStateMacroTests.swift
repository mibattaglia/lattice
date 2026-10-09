#if canImport(LatticeMacros)
    import LatticeMacros
    import MacroTesting
    import XCTest

    final class FeatureStateMacroTests: XCTestCase {
        override func invokeTest() {
            withMacroTesting(macros: [FeatureStateMacro.self, FeatureStateTrackedMacro.self, DomainMacro.self]) {
                super.invokeTest()
            }
        }

        func testTrackedObserversRemainOnStoredPeerWithRawParameters() {
            assertMacro {
                """
                @FeatureStateTracked
                public private(set) var value: Int = 0 {
                    willSet(incoming) { record(incoming) }
                    didSet { record(oldValue) }
                }
                """
            } expansion: {
                """
                public private(set) var value: Int {
                    willSet(incoming) { record(incoming) }
                    didSet { record(oldValue) }
                    @storageRestrictions(initializes: _feature_value)
                    init(initialValue) {
                        _feature_value = Lattice._FeatureStateTracked(initialValue)
                    }

                    get {
                        _feature_value.value
                    }

                    set {
                        _feature_value.value = newValue
                    }

                    _modify {
                        yield &_feature_value.value
                    }
                }

                private var _feature_value: Lattice._FeatureStateTracked<Int> = Lattice._FeatureStateTracked(0) {
                    willSet(incoming) {
                    let incoming = incoming._untrackedValue
                    _ = incoming
                    do {
                        record(incoming)
                    }
                    }
                    didSet {
                    let oldValue = oldValue._untrackedValue
                    _ = oldValue
                    do {
                        record(oldValue)
                    }
                    }
                }
                """
            }
        }

        func testEnumPayloadExtractionStaysInsideFilteredMetadata() {
            assertMacro {
                """
                @FeatureState
                enum Phase {
                    case idle
                    case ready(Child)
                    case count(Int)
                }
                """
            } expansion: {
                """
                enum Phase {
                    case idle
                    case ready(Child)
                    case count(Int)

                    var _featureStateIdentity: Lattice._FeatureStateIdentity {
                        switch self {
                        case .idle:
                            return .case(0, nil)
                        case .ready(let value):
                            return Lattice._featureStateCaseIdentity(1, value)
                        case .count(let value):
                            return Lattice._featureStateCaseIdentity(2, value)
                        }
                    }

                    struct _ViewMembers {
                        let ready = Lattice._featureStateCaseMember { (state: Phase) -> Child? in
                            guard case .ready(let value) = state else {
                                return nil
                            }
                            return value
                        }
                        let count = Lattice._featureStateCaseMember { (state: Phase) -> Int? in
                            guard case .count(let value) = state else {
                                return nil
                            }
                            return value
                        }
                        nonisolated init() {
                            Lattice._validateFeatureStateMember(ready)
                            Lattice._validateFeatureStateMember(count)
                        }
                    }

                    static var _viewMembers: _ViewMembers {
                        _ViewMembers()
                    }
                }
                """
            }
        }

        func testMissingTypeDiagnostic() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    var value = 1
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 view-visible members need an explicit type annotation for generated member metadata
                struct State {
                    var value = 1
                }
                """
            }
        }

        func testClassDiagnostic() {
            assertMacro {
                """
                @FeatureState
                class State {}
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 '@FeatureState' can only be attached to structs and enums
                class State {}
                """
            }
        }

        func testGeneratedNameCollisionDiagnostic() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    var _viewMembers: Int = 0
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 '@FeatureState' generated-name collision with member metadata or tracked storage
                struct State {
                    var _viewMembers: Int = 0
                }
                """
            }
        }

        func testHiddenLazyInputIsNotSilentlyUntracked() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    @Domain lazy var hidden: Int = 0
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 lazy properties are unsupported by '@FeatureState', including hidden inputs
                struct State {
                    @Domain lazy var hidden: Int = 0
                }
                """
            }
        }

        func testHiddenWrapperIsNotSilentlyUntracked() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    @Wrapper private var hidden: Int = 0
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 property attributes/wrappers and member-specific availability are unsupported by '@FeatureState', including hidden stored inputs
                struct State {
                    @Wrapper private var hidden: Int = 0
                }
                """
            }
        }

        func testComputedSetterDiagnostic() {
            assertMacro {
                """
                @FeatureState
                struct State {
                    var value: Int { get { 0 } set {} }
                }
                """
            } diagnostics: {
                """
                @FeatureState
                ┬────────────
                ╰─ 🛑 view-visible computed properties must have a synchronous, nonmutating, get-only getter
                struct State {
                    var value: Int { get { 0 } set {} }
                }
                """
            }
        }

        func testDomainOutsideStateDiagnostic() {
            assertMacro {
                """
                @Domain var value: Int = 0
                """
            } diagnostics: {
                """
                @Domain var value: Int = 0
                ┬──────
                ╰─ 🛑 '@Domain' requires an instance property in an '@FeatureState' declaration
                """
            }
        }
    }
#endif
