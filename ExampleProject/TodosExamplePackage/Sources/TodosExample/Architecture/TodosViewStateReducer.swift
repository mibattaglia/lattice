import Lattice

@ViewStateReducer<TodosDomainState, TodosViewState>
struct TodosViewStateReducer {
    var body: some ViewStateReducerOf<Self> {
        Self.buildViewState { domainState, viewState in
            let visibleTodos = filteredTodos(from: domainState)
            let viewItems = visibleTodos.map { todo in
                TodoViewItem(id: todo.id, title: todo.title, isComplete: todo.isComplete)
            }

            viewState = .loaded(
                TodosViewContent(
                    newTodoText: domainState.newTodoText,
                    filter: domainState.filter,
                    todos: viewItems
                )
            )
        }
    }

    private func filteredTodos(from state: TodosDomainState) -> [TodosDomainState.TodoItem] {
        switch state.filter {
        case .all:
            return state.todos
        case .active:
            return state.todos.filter { !$0.isComplete }
        case .completed:
            return state.todos.filter { $0.isComplete }
        }
    }
}
