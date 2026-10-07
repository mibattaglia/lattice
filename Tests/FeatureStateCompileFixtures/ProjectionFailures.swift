import Lattice

@MainActor
func projectionFailure(_ projection: FeatureProjection<FixtureRoot<Int>>) {
    #if DOMAIN_ESCAPE
    _ = projection.child.secret
    #elseif PRIVATE_ESCAPE
    _ = projection.child.privateValue
    #elseif FILEPRIVATE_ESCAPE
    _ = projection.child.fileValue
    #elseif RAW_CHILD_ESCAPE
    let _: FixtureChild = projection.child
    #elseif COMPOSED_NAMESPACE_PATH
    _ = \FixtureRoot<Int>._ViewMembers.child.secret
    #elseif OPTIONAL_ESCAPE
    _ = projection.optional?.secret
    #elseif CASE_ESCAPE
    _ = projection.phase.ready?.secret
    #elseif ROW_ESCAPE
    _ = projection.rows[id: 1]?.secret
    #elseif RAW_OPTIONAL_ESCAPE
    let _: FixtureChild? = projection.optional
    #elseif DESCRIPTOR_STORAGE_ESCAPE
    _ = FixtureRoot<Int>._viewMembers.child.keyPath
    #endif
}
