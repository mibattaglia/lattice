import Lattice
import SwiftUI

public struct TodosExampleAppView: View {
    @State private var viewModel: ViewModel<TodosEvent, TodosDomainState, TodosViewState>

    public init() {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialDomainState: TodosDomainState(),
                initialViewState: .loaded(
                    TodosViewContent(newTodoText: "", filter: .all, todos: [])
                ),
                interactor: TodosInteractor().eraseToAnyInteractor(),
                viewStateReducer: TodosViewStateReducer().eraseToAnyReducer()
            )
        )
    }

    public var body: some View {
        TodosView(viewModel: viewModel)
    }
}
