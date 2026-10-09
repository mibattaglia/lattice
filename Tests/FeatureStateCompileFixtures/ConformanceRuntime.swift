import CasePaths
import Lattice
import Observation

nonisolated private enum ConformanceAction: Sendable {
    case replace(FixturePhase)
    case title(String)
}

nonisolated private enum ScalarContextAction: Sendable {
    case nested(FixturePhase)
    case optional(FixturePhase?)
}

@main
private struct ConformanceRuntime {
    @MainActor
    static func main() {
        func equal<Value: Equatable>(_ lhs: Value, _ rhs: Value) -> Bool { lhs == rhs }
        let lhs = FixtureNominalEquality(value: 1)
        let rhs = FixtureNominalEquality(value: 1)
        precondition(equal(lhs, rhs))
        precondition(lhs.probe.count == 1)
        precondition([lhs] == [rhs])
        precondition(lhs.probe.count == 2)
        precondition(!equal(lhs, FixtureNominalEquality(value: 2)))
        precondition(lhs.probe.count == 3)

        let observerSnapshot = FixtureObservedValue()
        var observerSetter = observerSnapshot
        observerSetter.value = -1
        precondition(observerSetter.value == 0 && observerSetter.oldValues == [0, -1])
        var observerModify = observerSnapshot
        func assign(_ value: inout Int, _ replacement: Int) { value = replacement }
        assign(&observerModify.value, -1)
        precondition(observerModify.value == 0 && observerModify.oldValues == [0, -1])
        precondition(observerSnapshot.value == 0 && observerSnapshot.oldValues.isEmpty)
        for modify in [false, true] {
            var observer = observerSnapshot
            observer.reenterWillSet = true
            if modify { assign(&observer.value, 2) } else { observer.value = 2 }
            precondition(observer.value == 2 && observer.oldValues == [0, 0])
        }
        print("PASS: stored observer raw parameters/shadowing; outer oldValue before reentrant willSet; reference-compatible normalization calls=2 (not native equivalence)")

        let payload = FixtureChild()
        let equalPayload = FixtureChild()
        precondition(equal(payload, equalPayload))
        precondition(payload._featureStateIdentity != equalPayload._featureStateIdentity)
        precondition(equal(FixturePhase.ready(payload), .ready(equalPayload)))
        precondition(!equal(FixturePhase.ready(payload), .alternate(payload)))
        precondition(FixturePhase.ready(payload)._featureStateIdentity != FixturePhase.alternate(payload)._featureStateIdentity)
        precondition(FixturePhase.idle.domainSummary == "Hand-authored domain member")

        let path: CaseKeyPath<FixtureCasePathPhase, FixtureChild> = \.ready
        precondition(path(payload)[case: path]?.title == "Visible")

        let model = ViewModel(initialDomainState: FixturePhase.ready(payload), feature: Feature(
            interactor: Interact<FixturePhase, ConformanceAction> { state, action in
                switch action {
                case .replace(let replacement): state = replacement
                case .title(let title):
                    if case .ready(var child) = state {
                        child.title = title
                        state = .ready(child)
                    }
                }
                return .none
            }
        ))
        guard let held = model.scopeIfPresent(state: \.ready) else { preconditionFailure("Missing ready scope") }
        let cases = FixtureEqualityProbe()
        withObservationTracking { _ = model.scopeIfPresent(state: \.ready) } onChange: { cases.increment() }
        model.sendViewEvent(.replace(.alternate(payload)))
        precondition(cases.count == 1)
        precondition(model.scopeIfPresent(state: \.ready) == nil)
        precondition(held.title == "Visible")
        model.sendViewEvent(.replace(.idle))
        precondition(model.scopeIfPresent(state: \.alternate) == nil)
        var returning = payload
        returning.title = "Returned"
        let reconnected = FixtureEqualityProbe()
        withObservationTracking { _ = held.title } onChange: { reconnected.increment() }
        model.sendViewEvent(.replace(.ready(returning)))
        precondition(reconnected.count == 1)
        precondition(held.title == "Returned")
        withObservationTracking { _ = held.title } onChange: { reconnected.increment() }
        model.sendViewEvent(.title("Current"))
        precondition(reconnected.count == 2)
        precondition(held.title == "Current")
        model.sendViewEvent(.replace(.count(1)))
        let scalarChanges = FixtureEqualityProbe()
        withObservationTracking { _ = model.count } onChange: { scalarChanges.increment() }
        model.sendViewEvent(.replace(.count(2)))
        precondition(scalarChanges.count == 1 && model.count == 2)
        withObservationTracking { _ = model.count } onChange: { scalarChanges.increment() }
        model.sendViewEvent(.replace(.count(2)))
        precondition(scalarChanges.count == 1)
        model.sendViewEvent(.replace(.otherCount(2)))
        precondition(scalarChanges.count == 2 && model.count == nil && model.otherCount == 2)
        withObservationTracking { _ = model.otherCount } onChange: { scalarChanges.increment() }
        model.sendViewEvent(.replace(.count(2)))
        precondition(scalarChanges.count == 3 && model.count == 2)
        withObservationTracking { _ = model.count } onChange: { scalarChanges.increment() }
        model.sendViewEvent(.replace(.ready(payload)))
        precondition(scalarChanges.count == 4 && model.count == nil)
        withObservationTracking { _ = model.count } onChange: { scalarChanges.increment() }
        model.sendViewEvent(.title("Mixed tracked case"))
        precondition(scalarChanges.count == 4)
        precondition(model.scopeIfPresent(state: \.ready)?.title == "Mixed tracked case")
        model.binding(\.count, sending: { .replace($0.map(FixturePhase.count) ?? .idle) }).wrappedValue = 3
        precondition(model.count == 3)

        model.sendViewEvent(.replace(.text("Scalar")))
        precondition(model.text == "Scalar")
        model.sendViewEvent(.replace(.flag(true)))
        precondition(model.flag == true)
        model.sendViewEvent(.replace(.character("A")))
        precondition(model.character == "A")
        model.sendViewEvent(.replace(.int8(8)))
        precondition(model.int8 == 8)
        model.sendViewEvent(.replace(.int16(16)))
        precondition(model.int16 == 16)
        model.sendViewEvent(.replace(.int32(32)))
        precondition(model.int32 == 32)
        model.sendViewEvent(.replace(.int64(64)))
        precondition(model.int64 == 64)
        model.sendViewEvent(.replace(.unsigned(1)))
        precondition(model.unsigned == 1)
        model.sendViewEvent(.replace(.uint8(8)))
        precondition(model.uint8 == 8)
        model.sendViewEvent(.replace(.uint16(16)))
        precondition(model.uint16 == 16)
        model.sendViewEvent(.replace(.uint32(32)))
        precondition(model.uint32 == 32)
        model.sendViewEvent(.replace(.uint64(64)))
        precondition(model.uint64 == 64)
        model.sendViewEvent(.replace(.float(1.5)))
        precondition(model.float == 1.5)
        model.sendViewEvent(.replace(.double(2.5)))
        precondition(model.double == 2.5)
        precondition(_featureStateCaseIdentity(0, Int(1)) != _featureStateCaseIdentity(0, UInt(1)))
        precondition(_featureStateCaseIdentity(0, Int(1)) != _featureStateCaseIdentity(0, Double(1)))

        let contexts = ViewModel(initialDomainState: FixtureScalarContexts(), feature: Feature(
            interactor: Interact<FixtureScalarContexts, ScalarContextAction> { state, action in
                switch action {
                case .nested(let replacement): state.nested = replacement
                case .optional(let replacement): state.optional = replacement
                }
                return .none
            }
        ))
        let nested = contexts.scope(state: \.nested)
        guard let optional = contexts.scopeIfPresent(state: \.optional) else { preconditionFailure("Missing optional enum") }
        let nestedChanges = FixtureEqualityProbe()
        let optionalChanges = FixtureEqualityProbe()
        withObservationTracking { _ = nested.count } onChange: { nestedChanges.increment() }
        withObservationTracking { _ = optional.count } onChange: { optionalChanges.increment() }
        contexts.sendViewEvent(.nested(.count(2)))
        precondition(nestedChanges.count == 1 && nested.count == 2 && optionalChanges.count == 0)
        withObservationTracking { _ = nested.count } onChange: { nestedChanges.increment() }
        contexts.sendViewEvent(.nested(.otherCount(2)))
        precondition(nestedChanges.count == 2 && nested.count == nil && nested.otherCount == 2)
        contexts.sendViewEvent(.optional(.count(2)))
        precondition(optionalChanges.count == 1 && optional.count == 2)
        contexts.sendViewEvent(.optional(nil))
        precondition(contexts.scopeIfPresent(state: \.optional) == nil && optional.count == 2)
        withObservationTracking { _ = optional.count } onChange: { optionalChanges.increment() }
        contexts.sendViewEvent(.optional(.count(3)))
        precondition(optionalChanges.count == 2 && optional.count == 3)
        withObservationTracking { _ = optional.count } onChange: { optionalChanges.increment() }
        contexts.sendViewEvent(.optional(.count(4)))
        precondition(optionalChanges.count == 3 && optional.count == 4)
        withObservationTracking { _ = optional.count } onChange: { optionalChanges.increment() }
        contexts.sendViewEvent(.optional(.otherCount(4)))
        precondition(optionalChanges.count == 4 && optional.count == nil && optional.otherCount == 4)
        print("PASS: nominal/generic/array Equatable witness=3; synthesized equality; tracked case retention; CasePaths; all 15 scalar types; root/nested/optional scalar observation and reobservation")
    }
}
