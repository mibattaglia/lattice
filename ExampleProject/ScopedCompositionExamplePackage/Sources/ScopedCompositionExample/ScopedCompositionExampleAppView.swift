import Lattice
import SwiftUI

public struct ScopedCompositionExampleAppView: View {
    @State private var viewModel: ScopedCompositionViewModel
    @State private var renderCounters = RenderCounters()

    public init() {
        let feature = Feature(interactor: ScopedCompositionInteractor())
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: ScopedCompositionState(),
                feature: feature
            )
        )
    }

    public var body: some View {
        ScopedCompositionView(viewModel: viewModel)
            .environment(\.renderCounters, renderCounters)
    }
}
