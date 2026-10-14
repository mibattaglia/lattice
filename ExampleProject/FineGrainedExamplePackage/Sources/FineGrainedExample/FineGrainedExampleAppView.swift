import Lattice
import SwiftUI

public struct FineGrainedExampleAppView: View {
    @State private var viewModel: FineGrainedViewModel

    public init() {
        let feature = Feature(interactor: FineGrainedInteractor())
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: FineGrainedState(),
                feature: feature
            )
        )
    }

    public var body: some View {
        FineGrainedView(viewModel: viewModel)
    }
}
