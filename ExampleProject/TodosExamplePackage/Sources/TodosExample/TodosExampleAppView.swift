import Lattice
import SwiftUI

public struct TodosExampleAppView: View {
    private typealias TodosFeature = Feature<TodosEvent, TodosDomainState, TodosViewState>
    @State private var viewModel: ViewModel<TodosFeature>

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
