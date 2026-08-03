import Lattice
import SwiftUI

public struct TimerLeakExampleAppView: View {
    @State private var viewModel: ViewModel<TimerLeakState, TimerLeakEvent>

    public init() {
        _viewModel = State(
            wrappedValue: ViewModel(
                initialState: TimerLeakState(),
                interactor: TimerLeakInteractor()
            )
        )
    }

    public var body: some View {
        TimerLeakView(viewModel: viewModel)
    }
}
