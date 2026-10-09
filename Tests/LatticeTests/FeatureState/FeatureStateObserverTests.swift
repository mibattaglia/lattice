import Lattice
import Observation
import Testing

@FeatureState
private struct ObservedMutationState: Sendable {
    @Domain let probe: MutationProbe
    var value: Int = 0 {
        willSet(incoming) { probe.append("will:\(value)->\(incoming)") }
        didSet { probe.append("did:\(oldValue)->\(value)") }
    }
    var child: MutationDetail = MutationDetail() {
        willSet { probe.append("will:\(child.title)->\(newValue.title)") }
        didSet(previous) { probe.append("did:\(previous.title)->\(child.title)") }
    }
}

private enum ObserverMutation: CaseIterable, Sendable {
    case scalarSetter, scalarModify, aggregateSetter, aggregateModify, childLeaf

    var isScalar: Bool { self == .scalarSetter || self == .scalarModify }

    func apply(to state: inout ObservedMutationState) {
        let probe = state.probe
        switch self {
        case .scalarSetter: state.value = 2
        case .scalarModify: replace(&state.value, with: 2, probe: probe)
        case .aggregateSetter: state.child = MutationDetail(title: "After")
        case .aggregateModify: replace(&state.child, with: MutationDetail(title: "After"), probe: probe)
        case .childLeaf: state.child.title = "After"
        }
    }

    func events(notification: String) -> [String] {
        let observers = isScalar
            ? ["will:0->2", "did:0->2"]
            : ["will:Detail->After", "did:Detail->After"]
        switch self {
        case .scalarSetter, .aggregateSetter, .childLeaf: return [notification] + observers
        case .scalarModify: return [notification, "yield", "changed"] + observers
        case .aggregateModify: return ["yield", "changed", notification] + observers
        }
    }
}

private func replace<Value>(_ value: inout Value, with replacement: Value, probe: MutationProbe) {
    probe.append("yield")
    value = replacement
    probe.append("changed")
}

@Suite
struct FeatureStateObserverTests {
    @Test(arguments: [false, true])
    func storedObserversFollowPerPropertyNotificationPhases(shared: Bool) {
        for mutation in ObserverMutation.allCases {
            let probe = MutationProbe()
            var state = ObservedMutationState(probe: probe)
            let snapshot = shared ? state : nil
            withObservationTracking {
                if mutation.isScalar { _ = state.value }
                else if mutation == .childLeaf { _ = state.child.title }
                else { _ = state.child }
            } onChange: {
                // A copied value can be read synchronously; the actively mutated
                // raw variable cannot be read through an overlapping inout access.
                probe.append(snapshot.map { "notify:\($0.value)/\($0.child.title)" } ?? "notify")
            }
            let container = MutationProbe()
            withObservationTracking { _ = state.child } onChange: { container.increment() }
            mutation.apply(to: &state)
            #expect(probe.log == mutation.events(notification: shared ? "notify:0/Detail" : "notify"))
            #expect(state.value == (mutation.isScalar ? 2 : 0))
            #expect(state.child.title == (mutation.isScalar ? "Detail" : "After"))
            #expect(container.count() == (mutation == .aggregateSetter || mutation == .aggregateModify ? 1 : 0))
            if let snapshot {
                #expect(snapshot.value == 0 && snapshot.child.title == "Detail")
                #expect(snapshot._featureStateIdentity == state._featureStateIdentity)
            }
        }
    }

    @Test
    func equalScalarSetterRunsObserversButOnlyModifyNotifies() {
        let probe = MutationProbe()
        var state = ObservedMutationState(probe: probe)
        withObservationTracking { _ = state.value } onChange: { probe.append("notify") }
        state.value = 0
        #expect(probe.log == ["will:0->0", "did:0->0"])
        state.value += 0
        #expect(probe.log == ["will:0->0", "did:0->0", "notify", "will:0->0", "did:0->0"])
    }

    @Test
    @MainActor
    func notificationCallbacksReadOldModelUntilPublicationOnEveryAccessorPath() {
        for mutation in ObserverMutation.allCases {
            let probe = MutationProbe()
            let model = ViewModel(initialDomainState: ObservedMutationState(probe: probe), feature: Feature(
                interactor: Interact<ObservedMutationState, ObserverMutation> { state, action in
                    action.apply(to: &state)
                    return .none
                },
                areStatesEqual: { _, _ in true }
            ))
            withObservationTracking {
                if mutation.isScalar { _ = model.value }
                else if mutation == .childLeaf { _ = model.scope(state: \.child).title }
                else { _ = model.scope(state: \.child) }
            } onChange: {
                // This test drives mutation on MainActor. Shared-copy callbacks
                // in production do not acquire this actor guarantee.
                MainActor.assumeIsolated {
                    probe.append("notify:\(model.value)/\(model.scope(state: \.child).title)")
                }
            }
            model.sendViewEvent(mutation)
            #expect(probe.log == mutation.events(notification: "notify:0/Detail"))
            #expect(model.value == (mutation.isScalar ? 2 : 0))
            #expect(model.scope(state: \.child).title == (mutation.isScalar ? "Detail" : "After"))
        }
    }

    @Test(arguments: [false, true])
    func oldValuePrecedesReentrantWillSetHelper(modify: Bool) {
        let probe = MutationProbe()
        var state = ReentrantWillSetState(probe: probe)
        if modify { replace(&state.value, with: 2, probe: probe) }
        else { state.value = 2 }
        #expect(state.value == 2)
        #expect(probe.log == (modify ? ["yield", "changed"] : []) + [
            "will:0->2", "will:0->1", "did:0->1", "did:0->2",
        ])
    }

    @Test(arguments: [false, true])
    func normalizingDidSetRetainsReferenceFacadeReentrancyLimitation(modify: Bool) {
        var native = NativeNormalizingObserver()
        var tracked = TrackedNormalizingObserver()
        if modify {
            setNegative(&native.value)
            setNegative(&tracked.value)
        } else {
            native.value = -1
            tracked.value = -1
        }
        #expect(native.value == 0 && native.calls == 1)
        // TCA26's stored-wrapper facade also calls twice. Moving the observer
        // does not make a write through the public accessor a direct storage
        // write. This is a documented limitation, not native-Swift equivalence.
        #expect(tracked.value == 0 && tracked.calls == 2)
    }
}

@FeatureState
private struct ReentrantWillSetState: Sendable {
    @Domain let probe: MutationProbe
    @Domain var entered: Bool = false
    var value: Int = 0 {
        willSet {
            probe.append("will:\(value)->\(newValue)")
            if !entered {
                entered = true
                changeThroughHelper()
            }
        }
        didSet { probe.append("did:\(oldValue)->\(value)") }
    }
    private mutating func changeThroughHelper() { value = 1 }
}

private struct NativeNormalizingObserver {
    var calls: Int = 0
    var value: Int = 0 {
        didSet {
            calls += 1
            if value < 0 { self.value = 0 }
        }
    }
}

@FeatureState
private struct TrackedNormalizingObserver {
    var calls: Int = 0
    var value: Int = 0 {
        didSet {
            calls += 1
            if value < 0 { self.value = 0 }
        }
    }
}

private func setNegative(_ value: inout Int) { value = -1 }
