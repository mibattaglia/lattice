import Lattice
import SwiftUI

public struct PhaseExampleAppView: View {
    @State private var viewModel: PhaseExampleViewModel

    public init() {
        let feature = Feature(
            interactor: PhaseInteractor(),
            reducer: PhaseViewStateReducer()
        )
        _viewModel = State(
            wrappedValue: ViewModel(
                initialDomainState: PhaseDomainState(),
                feature: feature
            )
        )
    }

    public var body: some View {
        PhaseExampleView(viewModel: viewModel)
    }
}
