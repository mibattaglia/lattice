import Foundation

struct TodosDomainState: Equatable, Sendable {
    var todos: [TodoItem] = []
    var filter: Filter = .all
    var newTodoText: String = ""
    var nextOrder: Int = 0

    struct TodoItem: Identifiable, Equatable, Sendable {
        let id: UUID
        var title: String
        var isComplete: Bool
        var order: Int
    }

    enum Filter: String, CaseIterable, Identifiable, Equatable, Sendable {
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
