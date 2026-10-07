import Lattice
import FeatureStateFixtureDefinitions

@MainActor
func externalFailure(_ projection: FeatureProjection<FixtureRoot<Int>>) {
    #if INTERNAL_ESCAPE
    _ = projection.moduleOnly
    #elseif PACKAGE_ESCAPE
    _ = projection.packageOnly
    #elseif EXTERNAL_DOMAIN_ESCAPE
    _ = projection.child.secret
    #elseif EXTERNAL_RAW_ESCAPE
    let _: FixtureChild = projection.child
    #endif
}
