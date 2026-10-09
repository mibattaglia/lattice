import Lattice

@FeatureState
private struct RuntimeRow: Sendable, Equatable, Identifiable {
    let id: Int
    var title: String
    @Domain var eligible: Bool = true
}

@FeatureState
private struct RuntimeRoot: Sendable, Equatable {
    @Domain var rows: [RuntimeRow] = [RuntimeRow(id: 1, title: "Milk")]
    var filteredRows: [RuntimeRow] { rows.filter(\.eligible).sorted { $0.title < $1.title } }
}

private enum RuntimeAction: Sendable { case duplicate, omit, rename, include }

@main
private struct ResultRuntime {
    @MainActor
    static func main() {
        var state = RuntimeRoot()
        #if DUPLICATE_READ
        state.rows.append(RuntimeRow(id: 1, title: "Duplicate"))
        #endif
        let interactor = Interact<RuntimeRoot, RuntimeAction> { state, action in
            switch action {
            case .duplicate: state.rows.append(RuntimeRow(id: 1, title: "Duplicate"))
            case .omit: state.rows[0].title = "Oat milk"; state.rows[0].eligible = false
            case .rename: state.rows[0].title = "Hidden"
            case .include: state.rows[0].eligible = true
            }
            return .none
        }
        let model = ViewModel(initialDomainState: state, feature: Feature(interactor: interactor))
        let held = model.filteredRows[0]
        #if DUPLICATE_COMMIT
        model.sendViewEvent(.duplicate)
        #else
        model.sendViewEvent(.omit)
        precondition(held.title == "Milk")
        model.sendViewEvent(.rename)
        precondition(held.title == "Milk")
        model.sendViewEvent(.include)
        precondition(held.title == "Hidden")
        print("PASS: ordinary-import result retention and reconnection")
        #endif
    }
}
