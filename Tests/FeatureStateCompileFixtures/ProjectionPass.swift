import Lattice
import SwiftUI

// Ordinary metadata access stays nonisolated; these are descriptors, not raw values.
nonisolated func genericMetadataPass<Value: Equatable & Sendable>(_: Value.Type) {
    let _: FeatureStateValueMember<FixtureRoot<Value>, Value> = FixtureRoot<Value>._viewMembers.value
    let _: FeatureStateChildMember<GenericStructures<Value>, GenericRow<Value>> = GenericStructures<Value>._viewMembers.child
    let _: FeatureStateOptionalMember<GenericStructures<Value>, GenericRow<Value>> = GenericStructures<Value>._viewMembers.optional
    let _: FeatureStateRowsMember<GenericStructures<Value>, GenericRow<Value>> = GenericStructures<Value>._viewMembers.computedRows
}

nonisolated func protocolMetadataPass<State: FeatureStateProtocol>(_: State.Type) -> State._ViewMembers { State._viewMembers }

nonisolated func scalarDeclarationMetadataPass() {
    let _: FeatureStateValueMember<FixtureScalarDeclaration, Int?> = FixtureScalarDeclaration._viewMembers.count
}

@MainActor
func modelPass(_ model: FixtureModel) {
    let _: Int = model.value
    let _: String = model.label
    let child = model.scope(state: \.child, action: \.child)
    let _: String = child.title
    let _: String = model.moduleOnly
    let _: String = model.packageOnly
    let _: Int = model.readOnly
    let _: String? = model.scopeIfPresent(state: \.optional)?.scope(state: \.child).title
    let _: String? = model.scope(state: \.phase).scopeIfPresent(state: \.ready)?.title
    let _: Int? = model.scope(state: \.phase).count
    let _: String? = model.scope(state: \.phase).text
    let _: Bool? = model.scope(state: \.phase).flag
    let _: String? = model.filteredRows.first?.title
    let _: Int? = model.filteredRows.first?.packageOnly
    let _: String? = model.filteredRows.first?.scope(state: \.child).label
    let _: Int = model.identifiedRows.count
    let _: Binding<String> = model.binding(\.query, sending: \.query)
    let _: Binding<String> = child.binding(\.title, sending: \.title)
    let _: Binding<String> = Bindable(model).query.sending(\.query)
    let binding = Binding(get: { model }, set: { _ in })
    let _: Binding<String> = binding.query.sending(\.query)
    let _: ScopedViewModel<FixtureChild, FixtureChildAction> = model.scope(state: \.child, action: { .child($0) })
}

@MainActor
struct OrdinaryRowsClient: View {
    let model: FixtureModel
    var body: some View {
        ForEach(model.filteredRows) { row in
            OrdinaryRowClient(row: row, onEvent: { model.sendViewEvent(.row(row.id, $0)) })
        }
    }
}

@MainActor
struct OrdinaryRowClient: View {
    let row: ScopedRowViewModel<FixtureRow>
    let onEvent: (FixtureChildAction) -> Void
    var body: some View {
        TextField("Title", text: Binding(get: { row.title }, set: { onEvent(.title($0)) }))
    }
}

@MainActor
func genericStructuresPass<Value: Equatable & Sendable>(_ model: ScopedViewModel<GenericStructures<Value>, Never>) {
    let _: Value = model.scope(state: \.child).value
    let _: Value? = model.scopeIfPresent(state: \.optional)?.value
    let _: Value? = model.rows.first?.value
    let _: Value? = model.computedRows.first?.value
}

@MainActor
func moreSyntaxPass<Value: Equatable & Sendable>(
    _ nested: ScopedViewModel<FixtureOuter<Value>.Inner, Never>,
    _ opaque: ScopedViewModel<OpaqueLeafRoot, Never>,
    _ generic: ScopedViewModel<WhereFixture<Value>, Never>,
    _ escaped: ScopedViewModel<EscapedFixture, Never>,
    _ outer: ScopedViewModel<OuterNestedFixture, Never>
) {
    let _: Value = nested.value
    let _: Int = nested.default
    let _: String = nested.label
    let _: Int = opaque.value.wholeValue
    let _: [Int] = opaque.primitives
    let _: Int? = opaque.optionalValue
    let _: Value = generic.value
    let _: String? = escaped.scopeIfPresent(state: \.default)?.title
    let _: Int = outer.scope(state: \.child).value
}
