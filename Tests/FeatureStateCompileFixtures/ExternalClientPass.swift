import Lattice
import SwiftUI
import FeatureStateFixtureDefinitions

@MainActor
func externalPass(_ model: FixtureModel) {
    let _: Int = model.value
    let _: String = model.label
    let _: String = model.scope(state: \.child).title
    let _: String? = model.filteredRows.first?.title
    let _: String? = model.scopeIfPresent(state: \.optional)?.scope(state: \.child).label
    let _: Binding<String> = model.binding(\.query, sending: { .query($0) })
    #if SAME_PACKAGE
    let _: String = model.packageOnly
    let _: Int? = model.filteredRows.first?.packageOnly
    #endif
}

@MainActor
struct ExternalRowsClient: View {
    let model: FixtureModel
    var body: some View {
        ForEach(model.filteredRows) { row in
            Text(row.title)
        }
    }
}
