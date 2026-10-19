import Foundation
import Lattice
import Testing

@testable import TodosExample

// The suite runs the feature under `TestModel`. The auto-sort delay runs on an `EffectClock`: the
// sort is asleep on it when its `send` returns, and `model.advance` moves the clock past the delay
// and lets the sort run.

@Suite
struct TodosTests {
    @Test
    func addToggleDeleteReorder() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.newTodoTextChanged("First")) { $0.newTodoText = "First" }
        await model.send(.addTodo) { appendTodo(title: "First", order: 0, in: &$0) }
        await model.send(.newTodoTextChanged("Second")) { $0.newTodoText = "Second" }
        await model.send(.addTodo) { appendTodo(title: "Second", order: 1, in: &$0) }

        let todos = await model.state.todos
        #expect(todos.count == 2)
        let firstId = todos[0].id
        let secondId = todos[1].id

        await model.send(.setTodoCompletion(id: firstId, isComplete: true)) {
            $0.todos[0].isComplete = true
        }

        await model.send(.deleteTodos(ids: [secondId])) {
            $0.todos.removeAll { $0.id == secondId }
            $0.nextOrder = 1
        }

        let remaining = await model.state.todos
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == firstId)
        #expect(remaining.first?.isComplete == true)

        await model.send(.newTodoTextChanged("Third")) { $0.newTodoText = "Third" }
        await model.send(.addTodo) { appendTodo(title: "Third", order: 1, in: &$0) }
        await model.send(.newTodoTextChanged("Fourth")) { $0.newTodoText = "Fourth" }
        await model.send(.addTodo) { appendTodo(title: "Fourth", order: 2, in: &$0) }

        // Moving "Fourth" to the top leaves the completed "First" above the active "Third",
        // which the pending sort will fix.
        let idsBeforeMove = await model.state.todos.map(\.id)
        await model.send(.moveTodos(ids: [idsBeforeMove[2]], destination: 0)) { state in
            state.todos.insert(state.todos.removeLast(), at: 0)
            normalizeTodoOrder(&state)
        }
        #expect(await model.state.todos.map(\.title) == ["Fourth", "First", "Third"])

        await model.advance(clock, by: .milliseconds(300))
        await model.expect { applyAutoSort(&$0) }  // the sort wrote the new order directly

        let sorted = await model.state.todos
        #expect(sorted.map(\.id) == [idsBeforeMove[2], idsBeforeMove[1], idsBeforeMove[0]])
        #expect(sorted.map(\.isComplete) == [false, false, true])
        await model.finish()
    }

    @Test
    func debouncedAutoSortMovesCompletedToBottom() async {
        let clock = EffectClock()
        let model = await makeModel(clock: clock)

        await model.send(.newTodoTextChanged("First")) { $0.newTodoText = "First" }
        await model.send(.addTodo) { appendTodo(title: "First", order: 0, in: &$0) }
        await model.send(.newTodoTextChanged("Second")) { $0.newTodoText = "Second" }
        await model.send(.addTodo) { appendTodo(title: "Second", order: 1, in: &$0) }

        let todos = await model.state.todos
        let firstId = todos[0].id
        let secondId = todos[1].id

        let autoSort = await model.send(.setTodoCompletion(id: firstId, isComplete: true)) {
            $0.todos[0].isComplete = true
        }
        #expect(autoSort != nil)  // the toggle started the delayed sort

        await model.advance(clock, by: .milliseconds(299))
        await model.expect { _ in }  // 1 ms short of the delay: the list is not sorted yet

        await model.advance(clock, by: .milliseconds(1))
        await model.expect { applyAutoSort(&$0) }

        #expect(await model.state.todos.map(\.id) == [secondId, firstId])
        await model.finish()
    }

    /// Toggling again within the delay replaces the waiting sort and starts the delay over:
    /// the list is sorted once, a full delay after the last toggle.
    @Test
    func togglingAgainRestartsTheAutoSortDelay() async {
        let clock = EffectClock()
        let todos = [
            makeTodo(title: "First", isComplete: false, order: 0),
            makeTodo(title: "Second", isComplete: false, order: 1),
            makeTodo(title: "Third", isComplete: false, order: 2),
        ]
        let model = await makeModel(
            initialState: TodosState(todos: todos, filter: .all, newTodoText: "", nextOrder: 3),
            clock: clock
        )

        await model.send(.setTodoCompletion(id: todos[0].id, isComplete: true)) { $0.todos[0].isComplete = true }
        await model.advance(clock, by: .milliseconds(200))

        await model.send(.setTodoCompletion(id: todos[1].id, isComplete: true)) {
            $0.todos[1].isComplete = true
        }

        await model.advance(clock, by: .milliseconds(100))
        await model.expect { _ in }  // the first toggle's delay is over, but its sort was cancelled

        await model.advance(clock, by: .milliseconds(199))
        await model.expect { _ in }  // a new, full delay: 1 ms short of it, still not sorted
        await model.advance(clock, by: .milliseconds(1))
        await model.expect { applyAutoSort(&$0) }

        #expect(await model.state.todos.map(\.title) == ["Third", "First", "Second"])
        await model.finish()
    }

    /// A toggle the interactor ignores (an unknown todo, or a value that is already set) performs
    /// nothing, so the sort an earlier toggle scheduled still runs on time. The sort is identified
    /// by a key, which only a new sort replaces; an anonymous effect would be cancelled by every
    /// `.setTodoCompletion`, ignored or not.
    @Test
    func ignoredTogglesLeaveThePendingSortAlone() async {
        let clock = EffectClock()
        let todos = [
            makeTodo(title: "First", isComplete: false, order: 0),
            makeTodo(title: "Second", isComplete: false, order: 1),
        ]
        let model = await makeModel(
            initialState: TodosState(todos: todos, filter: .all, newTodoText: "", nextOrder: 2),
            clock: clock
        )

        await model.send(.setTodoCompletion(id: todos[0].id, isComplete: true)) {
            $0.todos[0].isComplete = true
        }

        let ignored = [
            await model.send(.setTodoCompletion(id: todos[0].id, isComplete: true)),
            await model.send(.setTodoCompletion(id: UUID(), isComplete: true)),
        ]
        #expect(ignored.allSatisfy { $0 == nil })

        await model.advance(clock, by: .milliseconds(300))
        await model.expect { applyAutoSort(&$0) }  // the first toggle's sort ran on time

        #expect(await model.state.todos.map(\.title) == ["Second", "First"])
        await model.finish()
    }

    /// The filter picks the todos views show, `filteredTodos`, and leaves the todos themselves as
    /// they are.
    @Test
    func filterShowsExpectedItems() async {
        let todos = [
            makeTodo(title: "Active", isComplete: false, order: 0),
            makeTodo(title: "Done", isComplete: true, order: 1),
        ]
        let model = await makeModel(
            initialState: TodosState(todos: todos, filter: .all, newTodoText: "", nextOrder: 2),
            clock: EffectClock()
        )

        await model.send(.setFilter(.active)) { $0.filter = .active }
        #expect(await model.state.filteredTodos.map(\.title) == ["Active"])

        await model.send(.setFilter(.completed)) { $0.filter = .completed }
        #expect(await model.state.filteredTodos.map(\.title) == ["Done"])
        await model.finish()
    }
}

private func makeModel(
    initialState: TodosState = TodosState(),
    clock: EffectClock
) async -> TestModel<Feature<TodosEvent, TodosState>> {
    await TestModel(initialState: initialState, feature: makeTodosFeature(clock: clock))
}

/// The feature with state equality that ignores todo IDs, which the interactor generates.
private func makeTodosFeature(clock: EffectClock) -> Feature<TodosEvent, TodosState> {
    Feature(
        interactor: TodosInteractor(clock: clock, debounceDuration: .milliseconds(300)),
        areStatesEqual: todosStatesAreEqualIgnoringIDs
    )
}

private func todosStatesAreEqualIgnoringIDs(
    _ lhs: TodosState,
    _ rhs: TodosState
) -> Bool {
    guard lhs.filter == rhs.filter,
        lhs.newTodoText == rhs.newTodoText,
        lhs.nextOrder == rhs.nextOrder,
        lhs.todos.count == rhs.todos.count
    else {
        return false
    }

    return zip(lhs.todos, rhs.todos).allSatisfy { lhsTodo, rhsTodo in
        lhsTodo.title == rhsTodo.title
            && lhsTodo.isComplete == rhsTodo.isComplete
            && lhsTodo.order == rhsTodo.order
    }
}

private func appendTodo(
    title: String,
    order: Int,
    in state: inout TodosState
) {
    state.todos.append(
        .init(
            id: UUID(),
            title: title,
            isComplete: false,
            order: order
        )
    )
    state.newTodoText = ""
    state.nextOrder = order + 1
}

private func normalizeTodoOrder(_ state: inout TodosState) {
    for index in state.todos.indices {
        state.todos[index].order = index
    }
    state.nextOrder = state.todos.count
}

private func applyAutoSort(_ state: inout TodosState) {
    state.todos.sort(by: sortedTodos)
    normalizeTodoOrder(&state)
}

private func sortedTodos(
    _ lhs: TodosState.TodoItem,
    _ rhs: TodosState.TodoItem
) -> Bool {
    if lhs.isComplete != rhs.isComplete {
        return lhs.isComplete == false
    }
    return lhs.order < rhs.order
}

private func makeTodo(title: String, isComplete: Bool, order: Int) -> TodosState.TodoItem {
    TodosState.TodoItem(
        id: UUID(),
        title: title,
        isComplete: isComplete,
        order: order
    )
}
