import Lattice
import SwiftUI

public struct FineGrainedExampleAppView: View {
    @State private var viewModel: FineGrainedViewModel

    public init() {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: FineGrainedState(),
                interactor: FineGrainedInteractor()
            )
        )
    }

    public var body: some View {
        FineGrainedView(viewModel: viewModel)
    }
}
