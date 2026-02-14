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
        let viewModel = makeViewModel(clock: clock)

        viewModel.sendViewEvent(.newTodoTextChanged("First"))
        viewModel.sendViewEvent(.addTodo)
        viewModel.sendViewEvent(.newTodoTextChanged("Second"))
        viewModel.sendViewEvent(.addTodo)

        guard case .loaded(let content) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }

        #expect(content.todos.count == 2)
        let firstId = content.todos[0].id
        let secondId = content.todos[1].id

        viewModel.sendViewEvent(.setTodoCompletion(id: firstId, isComplete: true))
        viewModel.sendViewEvent(.deleteTodos(ids: [secondId]))

        guard case .loaded(let afterDelete) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }

        #expect(afterDelete.todos.count == 1)
        #expect(afterDelete.todos.first?.id == firstId)
        #expect(afterDelete.todos.first?.isComplete == true)

        viewModel.sendViewEvent(.newTodoTextChanged("Third"))
        viewModel.sendViewEvent(.addTodo)

        guard case .loaded(let beforeMove) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }

        let ids = beforeMove.todos.map(\.id)
        viewModel.sendViewEvent(.moveTodos(ids: [ids[1]], destination: 0))

        guard case .loaded(let afterMove) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }

        #expect(afterMove.todos.first?.id == ids[1])
    }

    @Test
    func debouncedAutoSortMovesCompletedToBottom() async throws {
        let clock = TestClock()
        let viewModel = makeViewModel(clock: clock)

        viewModel.sendViewEvent(.newTodoTextChanged("First"))
        viewModel.sendViewEvent(.addTodo)
        viewModel.sendViewEvent(.newTodoTextChanged("Second"))
        viewModel.sendViewEvent(.addTodo)

        guard case .loaded(let content) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }

        let firstId = content.todos[0].id
        let secondId = content.todos[1].id

        let task = viewModel.sendViewEvent(.setTodoCompletion(id: firstId, isComplete: true))

        guard case .loaded(let beforeSort) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }

        #expect(beforeSort.todos.map(\.id) == [firstId, secondId])

        await clock.advance(by: .milliseconds(300))
        await task.finish()

        guard case .loaded(let afterSort) = viewModel.viewState else {
            Issue.record("Expected loaded view state")
            return
        }

        #expect(afterSort.todos.map(\.id) == [secondId, firstId])
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

    private typealias TodosFeature = Feature<TodosEvent, TodosDomainState, TodosViewState>

    private func makeViewModel(clock: TestClock) -> ViewModel<TodosFeature> {
        let feature = Feature(
            interactor: TodosInteractor(clock: clock, debounceDuration: .milliseconds(300)),
            reducer: TodosViewStateReducer()
        )
        return ViewModel(
            initialDomainState: TodosDomainState(),
            feature: feature
        )
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
