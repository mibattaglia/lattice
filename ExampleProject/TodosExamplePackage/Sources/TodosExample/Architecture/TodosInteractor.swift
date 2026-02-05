import Foundation
import Lattice

@Interactor<TodosDomainState, TodosEvent>
struct TodosInteractor<C: Clock>: Sendable where C.Duration: Sendable {
    private let autoSortDebouncer: Debouncer<C, TodosEvent?>

    init(clock: C, debounceDuration: C.Duration) {
        self.autoSortDebouncer = Debouncer(for: debounceDuration, clock: clock)
    }

    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .newTodoTextChanged(let text):
                state.newTodoText = text
                return .none

            case .addTodo:
                let trimmed = state.newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }

                let newTodo = TodosDomainState.TodoItem(
                    id: UUID(),
                    title: trimmed,
                    isComplete: false,
                    order: state.nextOrder
                )
                state.todos.append(newTodo)
                state.nextOrder += 1
                state.newTodoText = ""
                return .none

            case .setTodoCompletion(let id, let isComplete):
                guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
                    return .none
                }
                guard state.todos[index].isComplete != isComplete else { return .none }
                state.todos[index].isComplete = isComplete
                return scheduleAutoSort()

            case .deleteTodos(let ids):
                guard !ids.isEmpty else { return .none }
                let idSet = Set(ids)
                state.todos.removeAll { idSet.contains($0.id) }
                normalizeOrder(&state)
                return .none

            case .moveTodos(let ids, let destination):
                moveTodos(in: &state, ids: ids, destination: destination)
                return .none

            case .setFilter(let filter):
                state.filter = filter
                return .none

            case .applyAutoSort:
                state.todos.sort(by: sortedTodos)
                normalizeOrder(&state)
                return .none
            }
        }
    }

    private func scheduleAutoSort() -> Emission<TodosEvent> {
        .perform { .applyAutoSort }
            .debounce(using: autoSortDebouncer)
    }

    private func sortedTodos(_ lhs: TodosDomainState.TodoItem, _ rhs: TodosDomainState.TodoItem) -> Bool {
        if lhs.isComplete != rhs.isComplete {
            return lhs.isComplete == false
        }
        return lhs.order < rhs.order
    }

    private func normalizeOrder(_ state: inout TodosDomainState) {
        for index in state.todos.indices {
            state.todos[index].order = index
        }
        state.nextOrder = state.todos.count
    }

    private func moveTodos(in state: inout TodosDomainState, ids: [UUID], destination: Int) {
        guard !ids.isEmpty else { return }

        let filteredIndices = filteredIndices(in: state.todos, filter: state.filter)
        guard !filteredIndices.isEmpty else { return }

        var filteredTodos = filteredIndices.map { state.todos[$0] }
        let idSet = Set(ids)
        let offsets = IndexSet(
            filteredTodos.enumerated().compactMap { idSet.contains($0.element.id) ? $0.offset : nil }
        )
        guard !offsets.isEmpty else { return }

        move(&filteredTodos, fromOffsets: offsets, toOffset: destination)

        for (index, originalIndex) in filteredIndices.enumerated() {
            state.todos[originalIndex] = filteredTodos[index]
        }
        normalizeOrder(&state)
    }

    private func filteredIndices(
        in todos: [TodosDomainState.TodoItem],
        filter: TodosDomainState.Filter
    ) -> [Int] {
        switch filter {
        case .all:
            return Array(todos.indices)
        case .active:
            return todos.indices.filter { !todos[$0].isComplete }
        case .completed:
            return todos.indices.filter { todos[$0].isComplete }
        }
    }

    private func move<T>(
        _ items: inout [T],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) {
        guard !offsets.isEmpty else { return }

        let removed = remove(&items, at: offsets)
        let targetIndex = min(destination, items.count)
        items.insert(contentsOf: removed, at: targetIndex)
    }

    private func remove<T>(_ items: inout [T], at offsets: IndexSet) -> [T] {
        var removed: [T] = []
        for offset in offsets.sorted(by: >) {
            removed.insert(items.remove(at: offset), at: 0)
        }
        return removed
    }
}

extension TodosInteractor where C == ContinuousClock {
    init() {
        self.init(clock: ContinuousClock(), debounceDuration: .milliseconds(300))
    }
}
