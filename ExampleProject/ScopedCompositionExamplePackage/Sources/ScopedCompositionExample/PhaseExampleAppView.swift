import Lattice
import SwiftUI

public struct PhaseExampleAppView: View {
    @State private var viewModel: PhaseExampleViewModel

    public init() {
        let feature = Feature(interactor: PhaseInteractor())
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: .loading,
                feature: feature
            )
        )
    }

    public var body: some View {
        PhaseExampleView(viewModel: viewModel)
    }
}
