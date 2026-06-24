import Lattice
import SwiftUI

public struct TimerLeakExampleAppView: View {
    @State private var viewModel: ViewModel<Feature<TimerLeakEvent, TimerLeakDomainState, TimerLeakViewState>>

    public init() {
        let feature = Feature(
            interactor: TimerLeakInteractor(),
            reducer: TimerLeakViewStateReducer()
        )
        _viewModel = State(
            wrappedValue: ViewModel(
                initialDomainState: TimerLeakDomainState(),
                feature: feature
            )
        )
    }

    public var body: some View {
        TimerLeakView(viewModel: viewModel)
    }
}
