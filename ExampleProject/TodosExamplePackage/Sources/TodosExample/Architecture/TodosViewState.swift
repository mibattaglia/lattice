import CasePaths
import Foundation
import Lattice

@CasePathable
@ObservableState
@dynamicMemberLookup
enum TodosViewState: Equatable {
    case loaded(TodosViewContent)
}

struct TodosViewContent: Equatable {
    var newTodoText: String
    var filter: TodosDomainState.Filter
    var todos: [TodoViewItem]
}

struct TodoViewItem: Equatable, Identifiable {
    let id: UUID
    let title: String
    var isComplete: Bool
}
