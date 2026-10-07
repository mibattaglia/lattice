import Lattice
import FeatureStateFixtureDefinitions

func externalMetadataPass<Value: Equatable>(_: Value.Type) -> ProjectionValueMember<FixtureRoot<Value>, Value> {
    FixtureRoot<Value>._viewMembers.value
}

func externalProtocolMetadataPass<State: FeatureStateProtocol>(_: State.Type) -> State._ViewMembers {
    State._viewMembers
}

@MainActor
func externalPass<Value: Equatable>(_ projection: FeatureProjection<FixtureRoot<Value>>) {
    let _: Value = projection.value
    let _: String = projection.child.title
    let _: Int = projection.readOnly
    #if SAME_PACKAGE
    let _: String = projection.packageOnly
    #endif
}
