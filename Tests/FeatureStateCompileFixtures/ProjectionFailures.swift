import Lattice
import SwiftUI

@MainActor
func failure(_ model: FixtureModel) {
    #if DOMAIN_ESCAPE
    let _: Int = model.hiddenCount
    #elseif PRIVATE_ESCAPE
    let _: Int = model.scope(state: \.child).privateValue
    #elseif FILEPRIVATE_ESCAPE
    let _: Int = model.scope(state: \.child).fileValue
    #elseif OPTIONAL_ESCAPE
    let _: Int? = model.scopeIfPresent(state: \.optional)?.scope(state: \.child).secret
    #elseif CASE_ESCAPE
    let _: Int? = model.scope(state: \.phase).scopeIfPresent(state: \.ready)?.secret
    #elseif ROW_ESCAPE
    let _: Bool? = model.filteredRows.first?.eligible
    #elseif ROW_PRIVATE_ESCAPE
    let _: Int? = model.filteredRows.first?.privateValue
    #elseif ROW_FILEPRIVATE_ESCAPE
    let _: Int? = model.filteredRows.first?.fileValue
    #elseif RAW_STATE_ESCAPE
    let _: FixtureRoot<Int> = model.state
    #elseif RAW_VIEW_STATE_ESCAPE
    let _: FixtureRoot<Int> = model.viewState
    #elseif RAW_SCOPE_STATE_ESCAPE
    let _: FixtureChild = model.scope(state: \.child).viewState
    #elseif RAW_CHILD_ESCAPE
    let _: FixtureChild = model[dynamicMember: \.child]
    #elseif RAW_OPTIONAL_ESCAPE
    let _: FixtureParent? = model[dynamicMember: \.optional]
    #elseif RAW_ARRAY_ESCAPE
    let _: [FixtureRow] = model[dynamicMember: \.filteredRows]
    #elseif RAW_ROW_ESCAPE
    let _: FixtureRow = model.filteredRows[0]
    #elseif RAW_COLLECTION_COERCION
    let _: [FixtureRow] = Array(model.filteredRows)
    #elseif TRANSPARENT_CHILD_ESCAPE
    let _: String = model.child.title
    #elseif RAW_READ_CLOSURE_ESCAPE
    let _: FixtureRoot<Int> = model.read { $0 }
    #elseif DESCRIPTOR_STORAGE_ESCAPE
    let _ = FixtureRoot<Int>._viewMembers.child.keyPath
    #elseif DESCRIPTOR_GETTER_ESCAPE
    let _ = FixtureRoot<Int>._viewMembers.filteredRows.read
    #elseif COMPOSED_NAMESPACE_PATH
    let _ = \FixtureRoot<Int>._ViewMembers.child.secret
    #elseif RAW_BINDING_ESCAPE
    let _: Binding<String> = model.binding(\FixtureRoot<Int>.child.title, sending: { .child(.title($0)) })
    #elseif HIDDEN_BINDING_ESCAPE
    let _: Binding<Int> = model.binding(\.hiddenCount, sending: { _ in .query("") })
    #elseif RAW_BINDABLE_ESCAPE
    let bindable = Bindable<FixtureModel>(wrappedValue: model)
    let _ = bindable[dynamicMember: \FixtureRoot<Int>.child].secret
    #elseif RAW_BINDING_MODEL_ESCAPE
    let binding = Binding(get: { model }, set: { _ in })
    let _ = binding[dynamicMember: \FixtureRoot<Int>.child].secret
    #elseif RAW_ROW_BINDING_ESCAPE
    let row = model.filteredRows[0]
    let _: FixtureRow = row.viewState
    #elseif SCOPED_HIDDEN_BINDING_ESCAPE
    let child = model.scope(state: \.child, action: \.child)
    let _: Binding<Int> = child.binding(\.secret, sending: { _ in .title("") })
    #endif
}
