import CasePaths
import Foundation

@CasePathable
enum TodosEvent: Equatable {
    case newTodoTextChanged(String)
    case addTodo
    case setTodoCompletion(id: UUID, isComplete: Bool)
    case deleteTodos(ids: [UUID])
    case moveTodos(ids: [UUID], destination: Int)
    case setFilter(TodosState.Filter)
}
