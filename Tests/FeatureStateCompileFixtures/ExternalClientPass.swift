import Lattice
import FeatureStateFixtureDefinitions

@MainActor
func externalPass<Value: Equatable>(_ projection: FeatureProjection<FixtureRoot<Value>>) {
    let _: Value = projection.value
    let _: String = projection.child.title
    let _: Int = projection.readOnly
    #if SAME_PACKAGE
    let _: String = projection.packageOnly
    #endif
}
