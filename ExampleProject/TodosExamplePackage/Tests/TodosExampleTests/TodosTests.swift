import Foundation
import Lattice
import Testing

@testable import TodosExample

// The feature runs under `TestModel`, so the suite is not `@MainActor` and every test that creates
// one is `@available(macOS 26, *)` (the package supports macOS 14). The auto-sort delay is a
// `GateClock`: a test waits until the sort is sleeping, then moves the clock past the delay.

@Suite
struct TodosTests {
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func addToggleDeleteReorder() async {
        let clock = GateClock()
        let model = await makeModel(clock: clock)

        await model.send(.newTodoTextChanged("First")) { $0.newTodoText = "First" }
        await model.send(.addTodo) { appendTodo(title: "First", order: 0, in: &$0) }
        await model.send(.newTodoTextChanged("Second")) { $0.newTodoText = "Second" }
        await model.send(.addTodo) { appendTodo(title: "Second", order: 1, in: &$0) }

        let todos = await model.state.todos
        #expect(todos.count == 2)
        let firstId = todos[0].id
        let secondId = todos[1].id

        let autoSort = await model.send(.setTodoCompletion(id: firstId, isComplete: true)) {
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

        let idsBeforeMove = await model.state.todos.map(\.id)
        await model.send(.moveTodos(ids: [idsBeforeMove[1]], destination: 0)) { state in
            state.todos.swapAt(0, 1)
            normalizeTodoOrder(&state)
        }
        #expect(await model.state.todos.first?.id == idsBeforeMove[1])

        await clock.waitForSleepers(1)
        clock.moveForward(by: .milliseconds(300))
        await autoSort?.value
        await model.expect { applyAutoSort(&$0) }  // the sort wrote the new order directly

        let sorted = await model.state.todos
        #expect(sorted.map(\.id) == [idsBeforeMove[1], idsBeforeMove[0]])
        #expect(sorted[0].isComplete == false)
        #expect(sorted[1].isComplete == true)
        await model.finish()
    }

    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func debouncedAutoSortMovesCompletedToBottom() async {
        let clock = GateClock()
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

        await clock.waitForSleepers(1)
        #expect(clock.pendingSleeps == [.milliseconds(300)])
        await model.expect { _ in }  // still waiting: the list is not sorted yet

        clock.moveForward(by: .milliseconds(300))
        await autoSort?.value
        await model.expect { applyAutoSort(&$0) }

        #expect(await model.state.todos.map(\.id) == [secondId, firstId])
        await model.finish()
    }

    /// Toggling again within the delay auto-cancels the waiting sort and starts the delay over:
    /// the list is sorted once, a full delay after the last toggle.
    @available(macOS 26, *)
    @Test(.timeLimit(.minutes(1)))
    func togglingAgainRestartsTheAutoSortDelay() async {
        let clock = GateClock()
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
        await clock.waitForSleepers(1)
        clock.moveForward(by: .milliseconds(200))

        let autoSort = await model.send(.setTodoCompletion(id: todos[1].id, isComplete: true)) {
            $0.todos[1].isComplete = true
        }
        await clock.waitForSleepers(1)
        #expect(clock.pendingSleeps == [.milliseconds(300)])  // a new, full delay

        clock.moveForward(by: .milliseconds(100))
        await model.expect { _ in }  // the first toggle's delay is over, but its sort was cancelled

        clock.moveForward(by: .milliseconds(200))
        await autoSort?.value
        await model.expect { applyAutoSort(&$0) }

        #expect(await model.state.todos.map(\.title) == ["Third", "First", "Second"])
        await model.finish()
    }

    @MainActor
    @Test
    func filterShowsExpectedItems() {
        let todos = [
            makeTodo(title: "Active", isComplete: false, order: 0),
            makeTodo(title: "Done", isComplete: true, order: 1),
        ]
        let viewModel = ViewModel(
            initialState: TodosState(
                todos: todos,
                filter: .all,
                newTodoText: "",
                nextOrder: 2
            ),
            feature: makeTodosFeature(clock: GateClock())
        )

        viewModel.sendViewEvent(.setFilter(.active))
        let activeTodos = viewModel.filteredTodos
        #expect(activeTodos.count == 1)
        #expect(activeTodos.first?.title == "Active")

        viewModel.sendViewEvent(.setFilter(.completed))
        let completedTodos = viewModel.filteredTodos
        #expect(completedTodos.count == 1)
        #expect(completedTodos.first?.title == "Done")
    }
}

@available(macOS 26, *)
private func makeModel(
    initialState: TodosState = TodosState(),
    clock: GateClock
) async -> TestModel<Feature<TodosEvent, TodosState>> {
    await TestModel(initialState: initialState, feature: makeTodosFeature(clock: clock))
}

/// The feature with state equality that ignores todo IDs, which the interactor generates.
private func makeTodosFeature(clock: GateClock) -> Feature<TodosEvent, TodosState> {
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
