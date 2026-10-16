import Foundation
import Lattice

/// The feature's one state. The full list stays domain-only; views read `filteredTodos`, the
/// todos the selected filter shows, and items hide their domain-only sort `order`.
@FeatureState
struct TodosState: Equatable {
    @Domain var todos: [TodoItem] = []
    var filter: Filter = .all
    var newTodoText = ""
    @Domain var nextOrder = 0

    /// The todos the selected filter shows, in list order.
    var filteredTodos: [TodoItem] {
        switch filter {
        case .all:
            return todos
        case .active:
            return todos.filter { !$0.isComplete }
        case .completed:
            return todos.filter { $0.isComplete }
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
