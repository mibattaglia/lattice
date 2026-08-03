import Clocks
import Foundation
import IdentifiedCollections
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
        let uuids = IncrementingUUIDs()
        let model = makeTestViewModel(clock: clock, uuids: uuids)

        await model.send(.newTodoTextChanged("First")) {
            $0.newTodoText = "First"
        }
        await model.send(.addTodo) { state in
            appendTodo(id: uuids[0], title: "First", order: 0, in: &state)
        }
        await model.send(.newTodoTextChanged("Second")) {
            $0.newTodoText = "Second"
        }
        await model.send(.addTodo) { state in
            appendTodo(id: uuids[1], title: "Second", order: 1, in: &state)
        }

        #expect(model.domainState.todos.count == 2)
        let firstId = uuids[0]
        let secondId = uuids[1]

        let task = await model.send(.setTodoCompletion(id: firstId, isComplete: true)) {
            $0.todos[id: firstId]?.isComplete = true
        }
        // Deleting the completed todo leaves the debounced auto-sort effect running; it
        // fires later against whatever the state is then (asserted below).
        await model.send(.deleteTodos(ids: [secondId])) {
            $0.todos.remove(id: secondId)
            $0.nextOrder = 1
        }

        #expect(model.domainState.todos.count == 1)
        #expect(model.domainState.todos.first?.id == firstId)
        #expect(model.domainState.todos.first?.isComplete == true)

        await model.send(.newTodoTextChanged("Third")) {
            $0.newTodoText = "Third"
        }
        await model.send(.addTodo) { state in
            appendTodo(id: uuids[2], title: "Third", order: 1, in: &state)
        }

        let idsBeforeMove = model.domainState.todos.ids.elements
        await model.send(.moveTodos(ids: [idsBeforeMove[1]], destination: 0)) { state in
            state.todos.swapAt(0, 1)
            normalizeOrder(&state)
        }

        #expect(model.domainState.todos.first?.id == idsBeforeMove[1])

        // Cross the debounce window: the auto-sort effect re-enters via modify.
        await clock.advance(by: .milliseconds(300))
        await task.finish()
        await model.expect { state in
            applyAutoSort(&state)
        }

        #expect(model.domainState.todos.ids.elements == [idsBeforeMove[1], idsBeforeMove[0]])
        #expect(model.domainState.todos[id: idsBeforeMove[1]]?.isComplete == false)
        #expect(model.domainState.todos[id: idsBeforeMove[0]]?.isComplete == true)
        await model.dismount()
    }

    @Test
    func debouncedAutoSortMovesCompletedToBottom() async throws {
        let clock = TestClock()
        let uuids = IncrementingUUIDs()
        let model = makeTestViewModel(clock: clock, uuids: uuids)

        await model.send(.newTodoTextChanged("First")) {
            $0.newTodoText = "First"
        }
        await model.send(.addTodo) { state in
            appendTodo(id: uuids[0], title: "First", order: 0, in: &state)
        }
        await model.send(.newTodoTextChanged("Second")) {
            $0.newTodoText = "Second"
        }
        await model.send(.addTodo) { state in
            appendTodo(id: uuids[1], title: "Second", order: 1, in: &state)
        }

        let firstId = uuids[0]
        let secondId = uuids[1]

        let task = await model.send(.setTodoCompletion(id: firstId, isComplete: true)) {
            $0.todos[id: firstId]?.isComplete = true
        }

        #expect(task.hasEffects)
        #expect(model.domainState.todos.ids.elements == [firstId, secondId])

        await clock.advance(by: .milliseconds(300))
        await task.finish()
        await model.expect { state in
            applyAutoSort(&state)
        }

        #expect(model.domainState.todos.ids.elements == [secondId, firstId])
        await model.dismount()
    }

    @Test
    func filterShowsExpectedItems() async throws {
        let clock = TestClock()
        let uuids = IncrementingUUIDs()
        let todos: IdentifiedArrayOf<TodosState.TodoItem> = [
            makeTodo(id: uuids[0], title: "Active", isComplete: false, order: 0),
            makeTodo(id: uuids[1], title: "Done", isComplete: true, order: 1),
        ]
        let model = TestViewModel(
            initialDomainState: TodosState(
                todos: todos,
                filter: .all,
                newTodoText: ""
            ),
            interactor: TodosInteractor(
                clock: clock,
                debounceDuration: .milliseconds(300),
                makeUUID: uuids.next
            )
        )

        await model.send(.setFilter(.active)) {
            $0.filter = .active
        }
        // View output is asserted by reading the projection — no ViewState fixtures.
        #expect(model.projection.visibleTodoIDs == [uuids[0]])

        await model.send(.setFilter(.completed)) {
            $0.filter = .completed
        }
        #expect(model.projection.visibleTodoIDs == [uuids[1]])
        await model.dismount()
    }

    private func makeTestViewModel(
        clock: TestClock,
        uuids: IncrementingUUIDs
    ) -> TestViewModel<TodosState, TodosEvent> {
        TestViewModel(
            initialDomainState: TodosState(),
            interactor: TodosInteractor(
                clock: clock,
                debounceDuration: .milliseconds(300),
                makeUUID: uuids.next
            )
        )
    }
}

/// Deterministic UUID source — a plain class; interactor dependencies need no Sendable.
private final class IncrementingUUIDs {
    private var generated: [UUID] = []
    private var index = 0

    subscript(_ position: Int) -> UUID {
        while generated.count <= position {
            generated.append(makeUUID(generated.count))
        }
        return generated[position]
    }

    func next() -> UUID {
        defer { index += 1 }
        return self[index]
    }

    private func makeUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

private func appendTodo(
    id: UUID,
    title: String,
    order: Int,
    in state: inout TodosState
) {
    state.todos.append(
        .init(
            id: id,
            title: title,
            isComplete: false,
            order: order
        )
    )
    state.newTodoText = ""
    state.nextOrder = order + 1
}

private func makeTodo(
    id: UUID,
    title: String,
    isComplete: Bool,
    order: Int
) -> TodosState.TodoItem {
    TodosState.TodoItem(
        id: id,
        title: title,
        isComplete: isComplete,
        order: order
    )
}
