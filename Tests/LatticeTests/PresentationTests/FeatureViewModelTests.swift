// Rewritten for the flipped host (plan 06 §5): `Feature` narrows to interactor + state type.

import Foundation
import Testing

@testable import Lattice

@FeatureState
struct CounterFeatureState {
    var count: Int = 0
    var name: String = "Dracula"
    var age: Int = 900
}

enum CounterFeatureAction: Equatable {
    case incrementCount
    case decrementCount
    case increaseAge
}

@Interactor<CounterFeatureState, CounterFeatureAction>
struct CounterFeatureInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, event in
            switch event {
            case .incrementCount:
                state.count += 1
            case .decrementCount:
                state.count -= 1
            case .increaseAge:
                state.age += 1
            }
        }
    }
}

@MainActor
@Suite
struct FeatureViewModelTests {
    let viewModel: ViewModel<CounterFeatureState, CounterFeatureAction>

    init() {
        let feature = Feature<CounterFeatureState, CounterFeatureAction>(
            interactor: CounterFeatureInteractor()
        )
        self.viewModel = ViewModel(
            initialState: .init(),
            feature: feature
        )
    }

    @Test
    func featureViewModel() {
        #expect(viewModel.count == 0)
        #expect(viewModel.name == "Dracula")

        viewModel.sendViewEvent(.incrementCount)
        #expect(viewModel.count == 1)

        viewModel.sendViewEvent(.incrementCount)
        #expect(viewModel.count == 2)

        viewModel.sendViewEvent(.decrementCount)
        #expect(viewModel.count == 1)

        viewModel.sendViewEvent(.increaseAge)
        #expect(viewModel.age == 901)
    }
}
