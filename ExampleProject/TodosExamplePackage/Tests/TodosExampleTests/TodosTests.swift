import Clocks
import Foundation
import Lattice
import Testing

@testable import TodosExample

private typealias TestClock = Clocks.TestClock<Swift.Duration>

@Suite
@MainActor
struct TodosTests {

    @Test
    func addToggleDeleteReorder() async throws {
        let clock = TestClock()
        let model = makeTestViewModel(clock: clock)

        try await model.send(.newTodoTextChanged("First")) {
            $0.newTodoText = "First"
        }
        try await model.send(.addTodo) { state in
            appendTodo(title: "First", order: 0, in: &state)
        }
        try await model.send(.newTodoTextChanged("Second")) {
            $0.newTodoText = "Second"
        }
        try await model.send(.addTodo) { state in
            appendTodo(title: "Second", order: 1, in: &state)
        }

        #expect(model.state.todos.count == 2)
        let firstId = model.state.todos[0].id
        let secondId = model.state.todos[1].id

        let task = try await model.send(.setTodoCompletion(id: firstId, isComplete: true)) {
            $0.todos[0].isComplete = true
        }

        try await model.send(.deleteTodos(ids: [secondId])) {
            $0.todos.removeAll { $0.id == secondId }
            $0.nextOrder = 1
        }

        #expect(model.state.todos.count == 1)
        #expect(model.state.todos.first?.id == firstId)
        #expect(model.state.todos.first?.isComplete == true)

        try await model.send(.newTodoTextChanged("Third")) {
            $0.newTodoText = "Third"
        }
        try await model.send(.addTodo) { state in
            appendTodo(title: "Third", order: 1, in: &state)
        }

        let idsBeforeMove = model.state.todos.map(\.id)
        try await model.send(.moveTodos(ids: [idsBeforeMove[1]], destination: 0)) { state in
            state.todos.swapAt(0, 1)
            normalizeTodoOrder(&state)
        }

        #expect(model.state.todos.first?.id == idsBeforeMove[1])

        await clock.advance(by: .milliseconds(300))
        try await task.finish()
        try await model.receive(.applyAutoSort) { state in
            applyAutoSort(&state)
        }

        #expect(model.state.todos.map(\.id) == [idsBeforeMove[1], idsBeforeMove[0]])
        #expect(model.state.todos[0].isComplete == false)
        #expect(model.state.todos[1].isComplete == true)
    }

    @Test
    func debouncedAutoSortMovesCompletedToBottom() async throws {
        let clock = TestClock()
        let model = makeTestViewModel(clock: clock)

        try await model.send(.newTodoTextChanged("First")) {
            $0.newTodoText = "First"
        }
        try await model.send(.addTodo) { state in
            appendTodo(title: "First", order: 0, in: &state)
        }
        try await model.send(.newTodoTextChanged("Second")) {
            $0.newTodoText = "Second"
        }
        try await model.send(.addTodo) { state in
            appendTodo(title: "Second", order: 1, in: &state)
        }

        let firstId = model.state.todos[0].id
        let secondId = model.state.todos[1].id

        let task = try await model.send(.setTodoCompletion(id: firstId, isComplete: true)) {
            $0.todos[0].isComplete = true
        }

        #expect(task.hasEffects)
        #expect(model.state.todos.map(\.id) == [firstId, secondId])

        await clock.advance(by: .milliseconds(300))
        try await task.finish()
        try await model.receive(.applyAutoSort) { state in
            applyAutoSort(&state)
        }

        #expect(model.state.todos.map(\.id) == [secondId, firstId])
    }

    @Test
    func filterShowsExpectedItems() async throws {
        let clock = TestClock()
        let todos = [
            makeTodo(title: "Active", isComplete: false, order: 0),
            makeTodo(title: "Done", isComplete: true, order: 1),
        ]
        let feature = Feature(
            interactor: TodosInteractor(clock: clock, debounceDuration: .milliseconds(300))
        )
        let viewModel = ViewModel(
            initialState: TodosState(
                todos: todos,
                filter: .all,
                newTodoText: "",
                nextOrder: 2
            ),
            feature: feature
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

    private func makeViewModel(
        clock: TestClock
    ) -> ViewModel<Feature<TodosEvent, TodosState>> {
        ViewModel(
            initialState: TodosState(),
            feature: makeTodosFeature(clock: clock)
        )
    }

    private func makeTestViewModel(
        clock: TestClock
    ) -> TestViewModel<Feature<TodosEvent, TodosState>> {
        TestViewModel(
            initialState: TodosState(),
            feature: makeTodosFeature(clock: clock)
        )
    }

    private func makeTodosFeature(
        clock: TestClock
    ) -> Feature<TodosEvent, TodosState> {
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
}
