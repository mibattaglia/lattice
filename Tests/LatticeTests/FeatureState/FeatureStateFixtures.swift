import IdentifiedCollections
@testable import Lattice

@MainActor
final class FeatureStateHost<State: FeatureStateProtocol> {
    var state: State
    let registrar = FeatureStateRegistrar()
    var projection: FeatureProjection<State> { FeatureProjection(read: { self.state }, registrar: registrar) }

    init(_ state: State) { self.state = state }
    func update(_ mutation: (inout State) -> Void) {
        let old = state
        mutation(&state)
        registrar.commit { State._commit(old: old, new: state, registrar: registrar, key: ProjectionKey()) }
    }
}

final class GetterCounts {
    var label = 0
    var other = 0
    var nilValue = 0
    var combined = 0
    var child = 0
    var optional = 0
    var rows = 0
}

@FeatureState
struct ObservedChild {
    @Domain var input: Int = 0
    @Domain var counts: GetterCounts = GetterCounts()
    var title: String = "Visible"
    var label: String { counts.label += 1; return "\(input)" }
}

@FeatureState
struct ObservedRow: Equatable, Identifiable {
    var id: Int
    var title: String
    @Domain var input: Int = 0
    var label: String { "\(input)" }
}

@FeatureState
struct CoarseChild: Equatable {
    var title: String
    @Domain var input: Int = 0
    var label: String { "\(input)" }
}

@FeatureState
struct ObservedState {
    @Domain var input: Int = 0
    @Domain var show: Bool = true
    @Domain var counts: GetterCounts = GetterCounts()
    var stored: Int = 0
    var child: ObservedChild = ObservedChild()
    var optional: ObservedChild? = ObservedChild()
    var rows: IdentifiedArrayOf<ObservedRow> = []
    var label: String { counts.label += 1; return "\(input / 2)" }
    var other: String { counts.other += 1; return "other \(input)" }
    var nilValue: Int? { counts.nilValue += 1; return show ? nil : input }
    var combined: String { counts.combined += 1; return label + other }
    var computedChild: CoarseChild { counts.child += 1; return CoarseChild(title: "\(input)", input: input) }
    var computedOptional: CoarseChild? {
        counts.optional += 1
        return show ? CoarseChild(title: "\(input)", input: input) : nil
    }
    var computedRows: IdentifiedArrayOf<ObservedRow> {
        counts.rows += 1
        return show ? [ObservedRow(id: input, title: "\(input)")] : []
    }
}

@FeatureState
indirect enum ObservedPhase {
    case idle
    case ready(CoarseChild)
    case nested(ObservedPhase)
    var isReady: Bool { if case .ready = self { true } else { false } }
}
