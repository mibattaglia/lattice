import CasePaths
import SwiftUI
import Testing

@testable import Lattice

@MainActor
@Suite
struct ViewModelBindingTests {
    @Test
    func testBindingFromStateViewModel() {
        typealias BindingFeature = Feature<BindingTestAction, BindingTestState, BindingTestState>

        var viewModel: ViewModel<BindingFeature> = .init(
            initialDomainState: BindingTestState(name: "Blob"),
            feature: Feature(interactor: BindingTestInteractor().eraseToAnyInteractorUnchecked())
        )

        let binding = Binding(
            get: { viewModel },
            set: { viewModel = $0 }
        )

        let nameBinding = binding.name.sending(\.nameChanged)
        nameBinding.wrappedValue = "Blob Jr."

        #expect(viewModel.viewState.name == "Blob Jr.")
    }

    @Test
    func testBindingFromFeatureViewModelAlias() {
        typealias BindingFeature = Feature<BindingTestAction, BindingTestState, BindingTestState>

        var viewModel: ViewModelOf<BindingFeature> = .init(
            initialDomainState: BindingTestState(name: "Blob"),
            feature: Feature(interactor: BindingTestInteractor().eraseToAnyInteractorUnchecked())
        )

        let binding = Binding(
            get: { viewModel },
            set: { viewModel = $0 }
        )

        let nameBinding = binding.name.sending(\.nameChanged)
        nameBinding.wrappedValue = "Blob III"

        #expect(viewModel.viewState.name == "Blob III")
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
            case .nameChanged(let name):
                state.name = name
                return .none
            }
        }
    }
}
