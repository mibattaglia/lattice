import Lattice
import IdentifiedCollections

#if MISSING_TYPE
@FeatureState struct Invalid { var value = 1 }
#elseif CLASS_STATE
@FeatureState final class Invalid { var value: Int = 1 }
#elseif LAZY_PROPERTY
@FeatureState struct Invalid { lazy var value: Int = 1 }
#elseif SETTABLE_GETTER
@FeatureState struct Invalid { var value: Int { get { 1 } set {} } }
#elseif ASYNC_GETTER
@FeatureState struct Invalid { var value: Int { get async { 1 } } }
#elseif THROWING_GETTER
@FeatureState struct Invalid { var value: Int { get throws { 1 } } }
#elseif MUTATING_GETTER
@FeatureState struct Invalid { var value: Int { mutating get { 1 } } }
#elseif CONDITIONAL_MEMBER
@FeatureState struct Invalid {
    #if os(macOS)
    var value: Int = 1
    #endif
}
#elseif MEMBER_AVAILABILITY
@FeatureState struct Invalid { @available(macOS 14, *) var value: Int = 1 }
#elseif PROPERTY_WRAPPER
@propertyWrapper struct Wrapper { var wrappedValue: Int }
@FeatureState struct Invalid { @Wrapper var value: Int = 1 }
#elseif GENERATED_COLLISION
@FeatureState struct Invalid { var _viewMembers: Int = 1 }
#elseif MULTI_PAYLOAD
@FeatureState enum Invalid { case pair(Int, String) }
#elseif CASE_COLLISION
@FeatureState enum Invalid { case ready(FixtureChild); var ready: Int { 1 } }
#elseif DOMAIN_OUTSIDE
@Domain var invalid: Int = 0
#elseif DOMAIN_STATIC
@FeatureState struct Invalid { @Domain static var value: Int = 1 }
#elseif NON_EQUATABLE_LEAF
struct Leaf {}
@FeatureState struct Invalid { var value: Leaf = Leaf() }
#elseif NON_EQUATABLE_COMPUTED_CHILD
@FeatureState struct Child { var value: Int = 0 }
@FeatureState struct Invalid { var value: Child { Child() } }
#elseif NON_EQUATABLE_COMPUTED_OPTIONAL
@FeatureState struct Child { var value: Int = 0 }
@FeatureState struct Invalid { var value: Child? { Child() } }
#elseif DOMAIN_NESTED_OUTSIDE
@FeatureState struct Outer {
    struct Inner { @Domain var value: Int = 0 }
}
#elseif NON_SENDABLE_DOMAIN
final class Reference {}
@FeatureState struct Invalid: Sendable { @Domain var reference: Reference = Reference() }
#elseif ARRAY_FEATURE
@FeatureState struct Invalid { var value: [FixtureChild] = [] }
#elseif OPTIONAL_ARRAY_FEATURE
@FeatureState struct Invalid { var value: [FixtureChild?]? = [] }
#elseif DICTIONARY_FEATURE
@FeatureState struct Invalid { var value: [Int: FixtureChild?]? = [:] }
#elseif SET_FEATURE
@FeatureState struct Child: Hashable { var value: Int = 0 }
@FeatureState struct Invalid { var value: Set<Child?>? = [] }
#elseif DERIVED_ARRAY_FEATURE
@FeatureState struct Invalid { var value: [FixtureChild] { [] } }
#elseif OPTIONAL_IDENTIFIED_FEATURE
@FeatureState struct Invalid { var value: IdentifiedArrayOf<FixtureRow>? = [] }
#elseif DICTIONARY_KEY_FEATURE
@FeatureState struct Child: Hashable { var value: Int = 0 }
@FeatureState struct Invalid { var value: [Child: Int]? = [:] }
#elseif DICTIONARY_BOTH_FEATURE
@FeatureState struct Child: Hashable { var value: Int = 0 }
@FeatureState struct Invalid { var value: [Child?: Child?]? = [:] }
#elseif ALIASED_ARRAY_FEATURE
typealias Children = [FixtureChild]
@FeatureState struct Invalid { var value: Children = [] }
#endif
