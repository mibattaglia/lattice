import Foundation
import Lattice

@Interactor<TodosState, TodosEvent>
struct TodosInteractor<C: Clock> {
    /// The pending auto-sort. An identified effect is replaced only by the next effect of its key
    /// and never auto-cancelled; an anonymous one would be cancelled by every `.setTodoCompletion`,
    /// including one the interactor ignores, and the list would stay unsorted.
    @EffectID var autoSort
    private let clock: C
    private let autoSortDelay: C.Duration

    /// - Parameter debounceDuration: How long the list must stay untoggled before it is sorted.
    init(clock: C, debounceDuration: C.Duration) {
        self.clock = clock
        self.autoSortDelay = debounceDuration
    }

    var body: some InteractorOf<Self> {
        Interact { state, event, effects in
            switch event {
            case .newTodoTextChanged(let text):
                state.newTodoText = text

            case .addTodo:
                let trimmed = state.newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                let newTodo = TodosState.TodoItem(
                    id: UUID(),
                    title: trimmed,
                    isComplete: false,
                    order: state.nextOrder
                )
                state.todos.append(newTodo)
                state.nextOrder += 1
                state.newTodoText = ""

            case .setTodoCompletion(let id, let isComplete):
                guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
                    return
                }
                guard state.todos[index].isComplete != isComplete else { return }
                state.todos[index].isComplete = isComplete
                // The debounced auto-sort: the next toggle within the delay replaces this sleeping
                // effect with its own. A toggle that returns above performs nothing, so it leaves
                // the pending sort alone (see `autoSort`).
                effects.perform(id: autoSort) {
                    try await clock.sleep(for: autoSortDelay)
                    try effects.modify { state in
                        state.todos.sort(by: sortedTodos)
                        normalizeOrder(&state)
                    }
                }

            case .deleteTodos(let ids):
                guard !ids.isEmpty else { return }
                let idSet = Set(ids)
                state.todos.removeAll { idSet.contains($0.id) }
                normalizeOrder(&state)

            case .moveTodos(let ids, let destination):
                moveTodos(in: &state, ids: ids, destination: destination)

            case .setFilter(let filter):
                state.filter = filter
            }
        }
    }

    private func sortedTodos(_ lhs: TodosState.TodoItem, _ rhs: TodosState.TodoItem) -> Bool {
        if lhs.isComplete != rhs.isComplete {
            return lhs.isComplete == false
        }
        return lhs.order < rhs.order
    }

    private func normalizeOrder(_ state: inout TodosState) {
        for index in state.todos.indices {
            state.todos[index].order = index
        }
        state.nextOrder = state.todos.count
    }

    private func moveTodos(in state: inout TodosState, ids: [UUID], destination: Int) {
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
        in todos: [TodosState.TodoItem],
        filter: TodosState.Filter
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
