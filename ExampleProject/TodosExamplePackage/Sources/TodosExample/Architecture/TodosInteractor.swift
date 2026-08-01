import Foundation
import IdentifiedCollections
import Lattice

@Interactor<TodosState, TodosEvent>
struct TodosInteractor {
    private let clock: any Clock<Duration>
    private let debounceDuration: Duration
    private let makeUUID: () -> UUID

    init(
        clock: any Clock<Duration> = ContinuousClock(),
        debounceDuration: Duration = .milliseconds(300),
        makeUUID: @escaping () -> UUID = { UUID() }
    ) {
        self.clock = clock
        self.debounceDuration = debounceDuration
        self.makeUUID = makeUUID
    }

    var body: some InteractorOf<Self> {
        Interact { [clock, debounceDuration, makeUUID] state, event, effects in
            switch event {
            case .newTodoTextChanged(let text):
                state.newTodoText = text

            case .addTodo:
                let trimmed = state.newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                let newTodo = TodosState.TodoItem(
                    id: makeUUID(),
                    title: trimmed,
                    isComplete: false,
                    order: state.nextOrder
                )
                state.todos.append(newTodo)
                state.nextOrder += 1
                state.newTodoText = ""

            case .setTodoCompletion(let id, let isComplete):
                guard let current = state.todos[id: id]?.isComplete, current != isComplete
                else { return }
                state.todos[id: id]?.isComplete = isComplete
                // Debounced auto-sort by replacement: each completion toggle replaces the
                // previous in-flight task at this call site, restarting the quiet period.
                // The effect re-enters by mutating state directly — no `.applyAutoSort`
                // follow-up action exists anymore.
                effects.perform { effectState in
                    try await clock.sleep(for: debounceDuration)
                    try effectState.modify { state in
                        applyAutoSort(&state)
                    }
                }

            case .deleteTodos(let ids):
                guard !ids.isEmpty else { return }
                for id in ids {
                    state.todos.remove(id: id)
                }
                normalizeOrder(&state)

            case .moveTodos(let ids, let destination):
                moveTodos(in: &state, ids: ids, destination: destination)

            case .setFilter(let filter):
                state.filter = filter
            }
        }
    }
}

/// Sorts incomplete todos above completed ones, preserving relative order.
func applyAutoSort(_ state: inout TodosState) {
    var items = state.todos.elements
    items.sort(by: sortedTodos)
    state.todos = IdentifiedArray(uniqueElements: items)
    normalizeOrder(&state)
}

private func sortedTodos(_ lhs: TodosState.TodoItem, _ rhs: TodosState.TodoItem) -> Bool {
    if lhs.isComplete != rhs.isComplete {
        return lhs.isComplete == false
    }
    return lhs.order < rhs.order
}

func normalizeOrder(_ state: inout TodosState) {
    for (index, id) in state.todos.ids.enumerated() {
        state.todos[id: id]?.order = index
    }
    state.nextOrder = state.todos.count
}

private func moveTodos(in state: inout TodosState, ids: [UUID], destination: Int) {
    guard !ids.isEmpty else { return }

    var items = state.todos.elements
    let visibleIndices = filteredIndices(in: items, filter: state.filter)
    guard !visibleIndices.isEmpty else { return }

    var visibleTodos = visibleIndices.map { items[$0] }
    let idSet = Set(ids)
    let offsets = IndexSet(
        visibleTodos.enumerated().compactMap { idSet.contains($0.element.id) ? $0.offset : nil }
    )
    guard !offsets.isEmpty else { return }

    move(&visibleTodos, fromOffsets: offsets, toOffset: destination)

    for (index, originalIndex) in visibleIndices.enumerated() {
        items[originalIndex] = visibleTodos[index]
    }
    state.todos = IdentifiedArray(uniqueElements: items)
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
