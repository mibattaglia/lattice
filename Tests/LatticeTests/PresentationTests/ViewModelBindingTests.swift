import CasePaths
import SwiftUI
import Testing

@testable import Lattice

@MainActor
@Suite
struct ViewModelBindingTests {
    @Test
    func testBindingFromStateViewModel() {
        var viewModel = ViewModel(
            initialState: BindingTestState(name: "Blob"),
            interactor: BindingTestInteractor().eraseToAnyInteractorUnchecked()
        )

        let binding = Binding(
            get: { viewModel },
            set: { viewModel = $0 }
        )

        let nameBinding = binding.name.sending(\.nameChanged)
        nameBinding.wrappedValue = "Blob Jr."

        #expect(viewModel.viewState.name == "Blob Jr.")
    }
}

@ObservableState
private struct BindingTestState: Equatable, Sendable {
    var name: String
}

@CasePathable
private enum BindingTestAction: Sendable {
    case nameChanged(String)
}

@Interactor<BindingTestState, BindingTestAction>
private struct BindingTestInteractor: Interactor {
    var body: some InteractorOf<Self> {
        Interact { state, action in
            switch action {
            case let .nameChanged(name):
                state.name = name
                return .none
            }
        }
    }
}
