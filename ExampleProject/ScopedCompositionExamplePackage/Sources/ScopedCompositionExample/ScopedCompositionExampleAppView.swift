import Lattice
import SwiftUI

public struct ScopedCompositionExampleAppView: View {
    @State private var viewModel: ScopedCompositionViewModel

    public init() {
        let feature = Feature(
            interactor: ScopedCompositionInteractor(),
            reducer: ScopedCompositionViewStateReducer()
        )
        _viewModel = State(
            wrappedValue: ViewModel(
                initialDomainState: ScopedCompositionDomainState(),
                feature: feature
            )
        )
    }

    public var body: some View {
        ScopedCompositionView(viewModel: viewModel)
    }
}
