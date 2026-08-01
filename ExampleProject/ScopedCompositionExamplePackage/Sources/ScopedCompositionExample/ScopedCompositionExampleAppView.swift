import Lattice
import SwiftUI

public struct ScopedCompositionExampleAppView: View {
    @State private var viewModel: ScopedCompositionViewModel

    public init() {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: ScopedCompositionState(),
                interactor: ScopedCompositionInteractor()
            )
        )
    }

    public var body: some View {
        ScopedCompositionView(viewModel: viewModel)
    }
}
