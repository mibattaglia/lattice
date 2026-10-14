import Lattice
import SwiftUI

public struct TimerLeakExampleAppView: View {
    @State private var viewModel: ViewModel<Feature<TimerLeakEvent, TimerLeakState>>

    public init() {
        let feature = Feature(interactor: TimerLeakInteractor())
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: TimerLeakState(),
                feature: feature
            )
        )
    }

    public var body: some View {
        TimerLeakView(viewModel: viewModel)
    }
}
