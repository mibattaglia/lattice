import Foundation
import Lattice
import SwiftUI

struct TodosView: View {
    @Bindable private var viewModel: ViewModel<TodosState, TodosEvent>

    init(viewModel: ViewModel<TodosState, TodosEvent>) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    """
                    This view demonstrates a basic todo list with filtering,
                    reordering, and a debounced auto-sort that moves completed
                    items to the bottom.
                    """
                )
                .padding(.horizontal, 16)

                contentView
            }
            .navigationTitle("Todos")
            #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
                }
            #endif
        }
    }

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(
                    "New todo",
                    text: $viewModel.newTodoText.sending(\.newTodoTextChanged)
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.sendViewEvent(.addTodo) }

                Button("Add") {
                    viewModel.sendViewEvent(.addTodo)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 16)

            Picker("Filter", selection: $viewModel.filter.sending(\.setFilter)) {
                ForEach(TodosState.Filter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            // Collection-level structure (the filtered ids) is a derived member; each row is
            // read through the identity-keyed collection projection and re-renders only when
            // its own visible members change.
            let visibleIDs = viewModel.visibleTodoIDs
            if visibleIDs.isEmpty {
                Text("No todos yet")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                Spacer()
            } else {
                List {
                    ForEach(visibleIDs, id: \.self) { id in
                        if let item = viewModel.todos[id: id] {
                            HStack {
                                Toggle(
                                    isOn: Binding(
                                        get: { item.isComplete },
                                        set: { isComplete in
                                            viewModel.sendViewEvent(
                                                .setTodoCompletion(id: id, isComplete: isComplete)
                                            )
                                        }
                                    )
                                ) {
                                    Text(item.title)
                                        .strikethrough(item.isComplete, color: .secondary)
                                        .foregroundStyle(item.isComplete ? .secondary : .primary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { visibleIDs[$0] }
                        viewModel.sendViewEvent(.deleteTodos(ids: ids))
                    }
                    .onMove { offsets, destination in
                        let ids = offsets.map { visibleIDs[$0] }
                        viewModel.sendViewEvent(.moveTodos(ids: ids, destination: destination))
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
