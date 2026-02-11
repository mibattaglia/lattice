import Lattice
import SwiftUI

public struct TodosExampleAppView: View {
    @State private var viewModel: ViewModel<TodosEvent, TodosDomainState, TodosViewState>

    public init() {
        let feature = Feature(
            interactor: TodosInteractor(),
            reducer: TodosViewStateReducer()
        )
        _viewModel = State(
            wrappedValue: ViewModel(
                initialDomainState: TodosDomainState(),
                feature: feature
            )
        )
    }

    public var body: some View {
        TodosView(viewModel: viewModel)
    }
}
