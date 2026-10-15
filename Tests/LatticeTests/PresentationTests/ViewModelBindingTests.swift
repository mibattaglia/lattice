import CasePaths
import SwiftUI
import Testing

@testable import Lattice

@MainActor
@Suite
struct ViewModelBindingTests {
    @Test
    func testBindingFromStateViewModel() {
        var viewModel: ViewModel<Feature<BindingTestAction, BindingTestState>> = .init(
            initialState: BindingTestState(name: "Blob"),
            feature: Feature(interactor: BindingTestInteractor().eraseToAnyInteractor())
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
        var viewModel: ViewModel<Feature<BindingTestAction, BindingTestState>> = .init(
            initialState: BindingTestState(name: "Blob"),
            feature: Feature(interactor: BindingTestInteractor().eraseToAnyInteractor())
        )

        let binding = Binding(
            get: { viewModel },
            set: { viewModel = $0 }
        )

        let nameBinding = binding.name.sending(\.nameChanged)
        nameBinding.wrappedValue = "Blob III"

        #expect(viewModel.viewState.name == "Blob III")
    }

    @Test
    func bindableMemberBindingReadsTheViewStateAndSendsTheAction() {
        let viewModel = makeViewModel()
        let name = Bindable(viewModel).name.sending(\.nameChanged)
        #expect(name.wrappedValue == "Blob")

        name.wrappedValue = "Blob Sr."

        #expect(name.wrappedValue == "Blob Sr.")
        #expect(viewModel.name == "Blob Sr.")
    }

    @Test
    func bindableNestedMemberBindingGoesThroughTheChildProjection() {
        let viewModel = makeViewModel()
        let label = Bindable(viewModel).badge.label.sending(\.badge.labelChanged)
        #expect(label.wrappedValue == "New")

        label.wrappedValue = "Hot"

        #expect(viewModel.badge.label == "Hot")
    }

    @Test
    func caseBindingThroughFeatureStatePayloadProjection() {
        let viewModel = makeScreenViewModel(.loaded(BindingLoadedState(query: "", etag: "v1")))
        let query = Bindable(viewModel).loaded.query.sending(\.queryChanged)

        query.wrappedValue = "swift"

        #expect(query.wrappedValue == "swift")
        #expect(viewModel.viewState[case: \.loaded]?.query == "swift")
    }

    @Test
    func caseBindingThroughPlainPayload() {
        let viewModel = makeScreenViewModel(.failed(BindingFailure(message: "boom")))
        let message = Bindable(viewModel).failed.message.sending(\.failureMessageChanged)

        message.wrappedValue = "bang"

        #expect(message.wrappedValue == "bang")
        #expect(viewModel.viewState[case: \.failed]?.message == "bang")
    }

    @Test
    func caseBindingWithDefaultServesTheDefaultAndDropsSetsOutsideTheCase() {
        let viewModel = makeScreenViewModel(.failed(BindingFailure(message: "boom")))
        let query = Bindable(viewModel).loaded.query.sending(\.queryChanged, default: "none")

        #expect(query.wrappedValue == "none")
        query.wrappedValue = "swift"

        #expect(viewModel.viewState == .failed(BindingFailure(message: "boom")))
    }

    @Test
    func caseBindingFromBindingOfViewModel() {
        var viewModel = makeScreenViewModel(.loaded(BindingLoadedState()))
        let binding = Binding(
            get: { viewModel },
            set: { viewModel = $0 }
        )

        binding.loaded.query.sending(\.queryChanged).wrappedValue = "lattice"

        #expect(viewModel.viewState[case: \.loaded]?.query == "lattice")
    }

    private func makeViewModel() -> ViewModel<Feature<BindingTestAction, BindingTestState>> {
        ViewModel(
            initialState: BindingTestState(name: "Blob"),
            feature: Feature(interactor: BindingTestInteractor())
        )
    }

    private func makeScreenViewModel(
        _ initialState: BindingScreenState
    ) -> ViewModel<Feature<BindingScreenAction, BindingScreenState>> {
        ViewModel(initialState: initialState, feature: Feature(interactor: BindingScreenInteractor()))
    }
}

@FeatureState
struct BindingBadgeState: Equatable, Sendable {
    var label = "New"
}

@FeatureState
private struct BindingTestState: Equatable, Sendable {
    var name: String
    var badge = BindingBadgeState()
}

@CasePathable
enum BindingBadgeAction: Sendable {
    case labelChanged(String)
}

@CasePathable
private enum BindingTestAction: Sendable {
    case nameChanged(String)
    case badge(BindingBadgeAction)
}

@Interactor<BindingTestState, BindingTestAction>
private struct BindingTestInteractor: Interactor {
    var body: some InteractorOf<Self> {
        Interact { state, action, _ in
            switch action {
            case .nameChanged(let name):
                state.name = name
            case .badge(.labelChanged(let label)):
                state.badge.label = label
            }
        }
    }
}

@FeatureState
struct BindingLoadedState: Equatable, Sendable {
    var query = ""
    @Domain var etag: String?
}

struct BindingFailure: Equatable, Sendable {
    var message: String
}

@CasePathable
enum BindingScreenAction: Sendable {
    case queryChanged(String)
    case failureMessageChanged(String)
}

@Interactor<BindingScreenState, BindingScreenAction>
private struct BindingScreenInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, action, _ in
            switch action {
            case .queryChanged(let query):
                state.modify(\.loaded) { $0.query = query }
            case .failureMessageChanged(let message):
                state.modify(\.failed) { $0.message = message }
            }
        }
    }
}
