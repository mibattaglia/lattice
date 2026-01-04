import Foundation
import Testing

@testable import UnoArchitecture

@ObservableState
struct FeatureState: Equatable {
    var count = 0
    var name = "Dracula"
    var age = 900
}

enum FeatureAction: Equatable {
    case incrementCount
    case decrementCount
    case increaseAge
}

@Interactor<FeatureState, FeatureAction>
struct FeatureInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .incrementCount:
                state.count += 1
                return .state
            case .decrementCount:
                state.count -= 1
                return .state
            case .increaseAge:
                state.age += 1
                return .state
            }
        }
    }
}

@MainActor
@Suite
struct DirectViewModelTests {
    let interactor = FeatureInteractor()
    let viewModel: DirectViewModel<FeatureAction, FeatureState>

    init() {
        self.viewModel = DirectViewModel(
            initialState: .init(),
            interactor: interactor.eraseToAnyInteractor()
        )
    }

    @Test
    func directViewModel() {
        #expect(viewModel.viewState == FeatureState())

        viewModel.sendViewEvent(.incrementCount)
        #expect(viewModel.viewState == FeatureState(count: 1))

        viewModel.sendViewEvent(.incrementCount)
        #expect(viewModel.viewState == FeatureState(count: 2))

        viewModel.sendViewEvent(.decrementCount)
        #expect(viewModel.viewState == FeatureState(count: 1))

        viewModel.sendViewEvent(.increaseAge)
        #expect(viewModel.viewState == FeatureState(count: 1, age: 901))
    }
}
