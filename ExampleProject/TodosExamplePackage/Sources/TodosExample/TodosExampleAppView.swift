import Lattice
import SwiftUI

public struct TodosExampleAppView: View {
    @State private var viewModel: ViewModel<Feature<TodosEvent, TodosState>>

    public init() {
        let feature = Feature(interactor: TodosInteractor())
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: TodosState(),
                feature: feature
            )
        )
    }

    public var body: some View {
        TodosView(viewModel: viewModel)
    }
}
