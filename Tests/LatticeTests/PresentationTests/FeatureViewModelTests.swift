import Foundation
import Testing

@testable import Lattice

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
                return .none
            case .decrementCount:
                state.count -= 1
                return .none
            case .increaseAge:
                state.age += 1
                return .none
            }
        }
    }
}

@MainActor
@Suite
struct FeatureViewModelTests {
    let interactor = FeatureInteractor()
    typealias FeatureUnderTest = Feature<FeatureAction, FeatureState, FeatureState>
    let viewModel: ViewModelOf<FeatureUnderTest>

    init() {
        let feature = Feature(interactor: interactor.eraseToAnyInteractorUnchecked())
        self.viewModel = ViewModel(
            initialDomainState: .init(),
            feature: feature
        )
    }

    @Test
    func featureViewModel() {
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
