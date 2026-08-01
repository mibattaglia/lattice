import Foundation
import IdentifiedCollections
import Lattice

/// One state type replaces the old `TodosDomainState` + `TodosViewState` +
/// `TodosViewStateReducer` trio: stored members are the model, and the visible computed
/// members (`visibleTodoIDs`) are the collection-level structure the view renders from.
@FeatureState
struct TodosState: Equatable {
    @Domain var nextOrder: Int = 0

    var todos: IdentifiedArrayOf<TodoItem> = []
    var filter: Filter = .all
    var newTodoText: String = ""

    /// Collection-level structure (filtering) as a small derived value: the view iterates
    /// these ids and reads each row through the identity-keyed collection projection.
    var visibleTodoIDs: [UUID] {
        switch filter {
        case .all:
            return todos.ids.elements
        case .active:
            return todos.filter { !$0.isComplete }.map(\.id)
        case .completed:
            return todos.filter { $0.isComplete }.map(\.id)
        }
    }

    @FeatureState
    struct TodoItem: Identifiable, Equatable {
        let id: UUID
        var title: String
        var isComplete: Bool
        @Domain var order: Int
    }

    enum Filter: String, CaseIterable, Identifiable, Equatable {
        case all
        case active
        case completed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:
                return "All"
            case .active:
                return "Active"
            case .completed:
                return "Completed"
            }
        }
    }
}
