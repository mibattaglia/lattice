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

        #expect(model.domainState.todos.count == 2)
        let firstId = model.domainState.todos[0].id
        let secondId = model.domainState.todos[1].id

        let task = try await model.send(.setTodoCompletion(id: firstId, isComplete: true)) {
            $0.todos[0].isComplete = true
        }

        try await model.send(.deleteTodos(ids: [secondId])) {
            $0.todos.removeAll { $0.id == secondId }
            $0.nextOrder = 1
        }

        #expect(model.domainState.todos.count == 1)
        #expect(model.domainState.todos.first?.id == firstId)
        #expect(model.domainState.todos.first?.isComplete == true)

        try await model.send(.newTodoTextChanged("Third")) {
            $0.newTodoText = "Third"
        }
        try await model.send(.addTodo) { state in
            appendTodo(title: "Third", order: 1, in: &state)
        }

        let idsBeforeMove = model.domainState.todos.map(\.id)
        try await model.send(.moveTodos(ids: [idsBeforeMove[1]], destination: 0)) { state in
            state.todos.swapAt(0, 1)
            normalizeTodoOrder(&state)
        }

        #expect(model.domainState.todos.first?.id == idsBeforeMove[1])

        await clock.advance(by: .milliseconds(300))
        try await task.finish()
        try await model.receive(.applyAutoSort) { state in
            applyAutoSort(&state)
        }

        #expect(model.domainState.todos.map(\.id) == [idsBeforeMove[1], idsBeforeMove[0]])
        #expect(model.domainState.todos[0].isComplete == false)
        #expect(model.domainState.todos[1].isComplete == true)
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

        let firstId = model.domainState.todos[0].id
        let secondId = model.domainState.todos[1].id

        let task = try await model.send(.setTodoCompletion(id: firstId, isComplete: true)) {
            $0.todos[0].isComplete = true
        }

        #expect(task.hasEffects)
        #expect(model.domainState.todos.map(\.id) == [firstId, secondId])

        await clock.advance(by: .milliseconds(300))
        try await task.finish()
        try await model.receive(.applyAutoSort) { state in
            applyAutoSort(&state)
        }

        #expect(model.domainState.todos.map(\.id) == [secondId, firstId])
    }

    @Test
    func filterShowsExpectedItems() async throws {
        let clock = TestClock()
        let todos = [
            makeTodo(title: "Active", isComplete: false, order: 0),
            makeTodo(title: "Done", isComplete: true, order: 1),
        ]
        let feature = Feature(
            interactor: TodosInteractor(clock: clock, debounceDuration: .milliseconds(300)),
            reducer: TodosViewStateReducer()
        )
        let viewModel = ViewModel(
            initialDomainState: TodosDomainState(
                todos: todos,
                filter: .all,
                newTodoText: "",
                nextOrder: 2
            ),
            feature: feature
        )

        viewModel.sendViewEvent(.setFilter(.active))
        guard case .loaded(let activeContent) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }
        #expect(activeContent.todos.count == 1)
        #expect(activeContent.todos.first?.title == "Active")

        viewModel.sendViewEvent(.setFilter(.completed))
        guard case .loaded(let completedContent) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }
        #expect(completedContent.todos.count == 1)
        #expect(completedContent.todos.first?.title == "Done")
    }

    private func makeViewModel(
        clock: TestClock
    ) -> ViewModel<Feature<TodosEvent, TodosDomainState, TodosViewState>> {
        ViewModel(
            initialDomainState: TodosDomainState(),
            feature: makeTodosFeature(clock: clock)
        )
    }

    private func makeTestViewModel(
        clock: TestClock
    ) -> TestViewModel<Feature<TodosEvent, TodosDomainState, TodosViewState>> {
        TestViewModel(
            initialDomainState: TodosDomainState(),
            feature: makeTodosFeature(clock: clock)
        )
    }

    private func makeTodosFeature(
        clock: TestClock
    ) -> Feature<TodosEvent, TodosDomainState, TodosViewState> {
        Feature(
            interactor: TodosInteractor(clock: clock, debounceDuration: .milliseconds(300)),
            reducer: TodosViewStateReducer(),
            areStatesEqual: todosDomainStatesAreEqualIgnoringIDs
        )
    }

    private func todosDomainStatesAreEqualIgnoringIDs(
        _ lhs: TodosDomainState,
        _ rhs: TodosDomainState
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
        in state: inout TodosDomainState
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

    private func normalizeTodoOrder(_ state: inout TodosDomainState) {
        for index in state.todos.indices {
            state.todos[index].order = index
        }
        state.nextOrder = state.todos.count
    }

    private func applyAutoSort(_ state: inout TodosDomainState) {
        state.todos.sort(by: sortedTodos)
        normalizeTodoOrder(&state)
    }

    private func sortedTodos(
        _ lhs: TodosDomainState.TodoItem,
        _ rhs: TodosDomainState.TodoItem
    ) -> Bool {
        if lhs.isComplete != rhs.isComplete {
            return lhs.isComplete == false
        }
        return lhs.order < rhs.order
    }

    private func makeTodo(title: String, isComplete: Bool, order: Int) -> TodosDomainState.TodoItem {
        TodosDomainState.TodoItem(
            id: UUID(),
            title: title,
            isComplete: isComplete,
            order: order
        )
    }
}
