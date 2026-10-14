import Lattice
import SwiftUI

struct TodosView: View {
    @Bindable private var viewModel: ViewModel<Feature<TodosEvent, TodosState>>

    init(viewModel: ViewModel<Feature<TodosEvent, TodosState>>) {
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

                contentView(viewModel.viewState)
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

    private func contentView(_ content: TodosState.ViewState) -> some View {
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
                .disabled(content.newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)

            Picker("Filter", selection: $viewModel.filter.sending(\.setFilter)) {
                ForEach(TodosState.Filter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if content.filteredTodos.isEmpty {
                Text("No todos yet")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                Spacer()
            } else {
                List {
                    ForEach(content.filteredTodos) { item in
                        HStack {
                            Toggle(
                                isOn: Binding(
                                    get: { item.isComplete },
                                    set: { isComplete in
                                        viewModel.sendViewEvent(
                                            .setTodoCompletion(id: item.id, isComplete: isComplete)
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
                    .onDelete { offsets in
                        let ids = offsets.map { content.filteredTodos[$0].id }
                        viewModel.sendViewEvent(.deleteTodos(ids: ids))
                    }
                    .onMove { offsets, destination in
                        let ids = offsets.map { content.filteredTodos[$0].id }
                        viewModel.sendViewEvent(.moveTodos(ids: ids, destination: destination))
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
