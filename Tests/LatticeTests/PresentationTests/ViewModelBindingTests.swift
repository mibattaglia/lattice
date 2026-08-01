// Rewritten for the flipped host (plan 06 §4): binding read key paths retarget onto the
// state's `_ViewMembers` projection namespace; writes still send events.

import CasePaths
import SwiftUI
import Testing

@testable import Lattice

@FeatureState
private struct BindingTestState {
    var name: String = "Blob"
    var profile: BindingProfileState = BindingProfileState()
}

@FeatureState
private struct BindingProfileState: Equatable {
    var bio: String = "bio"
}

@CasePathable
private enum BindingTestAction {
    case nameChanged(String)
    case bioChanged(String)
}

private struct BindingTestInteractor: Interactor {
    var body: some Interactor<BindingTestState, BindingTestAction> {
        Interact { state, action in
            switch action {
            case .nameChanged(let name):
                state.name = name
            case .bioChanged(let bio):
                state.profile.bio = bio
            }
        }
    }
}

@MainActor
@Suite
struct ViewModelBindingTests {
    private func makeViewModel() -> ViewModel<BindingTestState, BindingTestAction> {
        ViewModel(initialState: BindingTestState(), interactor: BindingTestInteractor())
    }

    @Test
    func bindingFromBindingOfViewModelReadsAndSends() {
        var viewModel = makeViewModel()

        let binding = Binding(
            get: { viewModel },
            set: { viewModel = $0 }
        )

        let nameBinding = binding.name.sending(\.nameChanged)
        #expect(nameBinding.wrappedValue == "Blob")

        nameBinding.wrappedValue = "Blob Jr."
        #expect(viewModel.name == "Blob Jr.")
    }

    @Test
    func bindingFromBindableReadsAndSends() {
        let viewModel = makeViewModel()

        @Bindable var bindable = viewModel
        let nameBinding = $bindable.name.sending(\.nameChanged)

        #expect(nameBinding.wrappedValue == "Blob")
        nameBinding.wrappedValue = "Blob III"
        #expect(viewModel.name == "Blob III")
    }

    @Test
    func nestedMemberBindingChainsThroughTheFirstHop() {
        let viewModel = makeViewModel()

        @Bindable var bindable = viewModel
        let bioBinding = $bindable.profile.bio.sending(\.bioChanged)

        #expect(bioBinding.wrappedValue == "bio")
        bioBinding.wrappedValue = "updated"
        #expect(viewModel.profile.bio == "updated")
    }
}
