import Lattice

@MainActor
func projectionPass(_ projection: FeatureProjection<FixtureRoot<Int>>) {
    let _: Int = projection.value
    let _: String = projection.child.title
    let child: FeatureProjection<FixtureChild> = projection.child
    let _: String = child.title
    let _: String = projection.moduleOnly
    let _: String = projection.packageOnly
    let _: Int = projection.readOnly
}

@MainActor
func genericPass<Value: Equatable>(_ projection: FeatureProjection<FixtureRoot<Value>>) -> Value {
    projection.value
}

@MainActor
func structuredPass(_ projection: FeatureProjection<FixtureRoot<Int>>) {
    let _: String? = projection.optional?.title
    let _: String? = projection.phase.ready?.title
    let _: String? = projection.rows[id: 1]?.title
    let _: Int = projection.rows.count
}

@MainActor
func nestedPass<Value: Equatable>(
    _ nested: FeatureProjection<FixtureOuter<Value>.Inner>,
    _ selfState: FeatureProjection<SelfFixture>
) {
    let _: Value = nested.value
    let _: Int = nested.default
    let _: String = nested.label
    let _: Int = selfState.copy.value
}

@MainActor
func genericStructuresPass<Value: Equatable>(_ projection: FeatureProjection<GenericStructures<Value>>) {
    let _: Value = projection.child.value
    let _: Value? = projection.optional?.value
    let _: Value? = projection.rows[id: 1]?.value
    let _: Value = projection.computedChild.value
    let _: Value? = projection.computedOptional?.value
    let _: Value? = projection.computedRows[id: 1]?.value
}

@MainActor
func opaqueLeafPass(_ projection: FeatureProjection<OpaqueLeafRoot>) {
    let _: Int = projection.value.wholeValue
    let _: [Int] = projection.primitives
    let _: Int? = projection.optionalValue
}

@MainActor
func moreSyntaxPass<Value: Equatable>(
    _ generic: FeatureProjection<WhereFixture<Value>>,
    _ escaped: FeatureProjection<EscapedFixture>,
    _ nested: FeatureProjection<OuterNestedFixture>
) {
    let _: Value = generic.value
    let _: String? = escaped.default?.title
    let _: Int = nested.child.value
}
