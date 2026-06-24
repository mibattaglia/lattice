import Lattice
import SwiftUI

public struct FineGrainedExampleAppView: View {
    @State private var viewModel: FineGrainedViewModel

    public init() {
        let feature = Feature(
            interactor: FineGrainedInteractor(),
            reducer: FineGrainedViewStateReducer()
        )
        _viewModel = State(
            wrappedValue: ViewModel(
                initialDomainState: FineGrainedDomainState(),
                feature: feature
            )
        )
    }

    public var body: some View {
        FineGrainedView(viewModel: viewModel)
    }
}
