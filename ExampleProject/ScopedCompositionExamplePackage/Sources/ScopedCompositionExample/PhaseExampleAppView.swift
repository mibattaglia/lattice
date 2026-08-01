import Lattice
import SwiftUI

public struct PhaseExampleAppView: View {
    @State private var viewModel: PhaseExampleViewModel

    public init() {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: .loading,
                interactor: PhaseInteractor()
            )
        )
    }

    public var body: some View {
        PhaseExampleView(viewModel: viewModel)
    }
}
