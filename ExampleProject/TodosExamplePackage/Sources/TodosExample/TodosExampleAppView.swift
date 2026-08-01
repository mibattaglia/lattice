import Lattice
import SwiftUI

public struct TodosExampleAppView: View {
    @State private var viewModel: ViewModel<TodosState, TodosEvent>

    public init() {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: TodosState(),
                interactor: TodosInteractor()
            )
        )
    }

    public var body: some View {
        TodosView(viewModel: viewModel)
    }
}
