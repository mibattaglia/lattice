import Lattice
import FeatureStateFixtureDefinitions

@MainActor
func externalFailure(_ model: FixtureModel) {
    #if INTERNAL_ESCAPE
    let _: String = model.moduleOnly
    #elseif PACKAGE_ESCAPE
    let _: String = model.packageOnly
    #elseif ROW_INTERNAL_ESCAPE
    let _: Int? = model.filteredRows.first?.moduleOnly
    #elseif ROW_PACKAGE_ESCAPE
    let _: Int? = model.filteredRows.first?.packageOnly
    #elseif EXTERNAL_DOMAIN_ESCAPE
    let _: Bool? = model.filteredRows.first?.eligible
    #elseif EXTERNAL_RAW_ESCAPE
    let _: FixtureChild = model[dynamicMember: \.child]
    #elseif EXTERNAL_RAW_ARRAY_ESCAPE
    let _: [FixtureRow] = model.filteredRows
    #elseif EXTERNAL_RAW_ROW_ESCAPE
    let _: FixtureRow = model.filteredRows[0]
    #elseif EXTERNAL_ROW_PRIVATE_ESCAPE
    let _: Int? = model.filteredRows.first?.privateValue
    #elseif EXTERNAL_ROW_FILEPRIVATE_ESCAPE
    let _: Int? = model.filteredRows.first?.fileValue
    #endif
}
