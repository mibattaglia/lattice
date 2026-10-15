import Foundation
import Testing

@testable import Lattice

@FeatureState
struct FeatureTestState: Equatable {
    var count = 0
    var name = "Dracula"
    @Domain var age = 900
    var ageText: String { "\(name) is \(age)" }
}

enum FeatureAction: Equatable {
    case incrementCount
    case decrementCount
    case increaseAge
}

@Interactor<FeatureTestState, FeatureAction>
struct FeatureInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, event, _ in
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

/// Not `Equatable`, so `Feature(interactor:)` has no state equality for it.
@FeatureState
private struct UncomparableFeatureState {
    var count = 0
}

@Interactor<UncomparableFeatureState, FeatureAction>
private struct UncomparableFeatureInteractor {
    var body: some InteractorOf<Self> {
        Interact { state, _, _ in
            state.count += 1
        }
    }
}

@MainActor
@Suite
struct FeatureViewModelTests {
    let interactor = FeatureInteractor()
    let viewModel: ViewModel<Feature<FeatureAction, FeatureTestState>>

    init() {
        let feature = Feature(interactor: interactor.eraseToAnyInteractor())
        self.viewModel = ViewModel(
            initialState: .init(),
            feature: feature
        )
    }

    @Test
    func featureViewModel() {
        #expect(viewModel.viewState == FeatureTestState.ViewState(FeatureTestState()))

        viewModel.sendViewEvent(.incrementCount)
        #expect(viewModel.viewState == FeatureTestState.ViewState(FeatureTestState(count: 1)))

        viewModel.sendViewEvent(.incrementCount)
        #expect(viewModel.viewState == FeatureTestState.ViewState(FeatureTestState(count: 2)))

        viewModel.sendViewEvent(.decrementCount)
        #expect(viewModel.viewState == FeatureTestState.ViewState(FeatureTestState(count: 1)))

        viewModel.sendViewEvent(.increaseAge)
        #expect(viewModel.viewState == FeatureTestState.ViewState(FeatureTestState(count: 1, age: 901)))
    }

    @Test
    func visibleComputedMemberReadsDomainMember() {
        #expect(viewModel.ageText == "Dracula is 900")

        viewModel.sendViewEvent(.increaseAge)
        #expect(viewModel.ageText == "Dracula is 901")
    }

    @Test
    func equatableStateFeatureComparesStatesWithEquality() throws {
        let areStatesEqual = try #require(Feature(interactor: FeatureInteractor()).areStatesEqual)
        #expect(areStatesEqual(FeatureTestState(), FeatureTestState()))
        #expect(!areStatesEqual(FeatureTestState(), FeatureTestState(count: 1)))
    }

    @Test
    func nonEquatableStateFeatureHasNoStateEquality() {
        #expect(Feature(interactor: UncomparableFeatureInteractor()).areStatesEqual == nil)
    }

    @Test
    func explicitStateEqualityIsUsedAsIs() throws {
        let feature = Feature(
            interactor: FeatureInteractor(),
            areStatesEqual: { lhs, rhs in lhs.name == rhs.name }
        )
        let areStatesEqual = try #require(feature.areStatesEqual)
        #expect(areStatesEqual(FeatureTestState(count: 1), FeatureTestState(count: 2)))
        #expect(!areStatesEqual(FeatureTestState(), FeatureTestState(name: "Mina")))

        let withoutEquality = Feature(interactor: FeatureInteractor(), areStatesEqual: nil)
        #expect(withoutEquality.areStatesEqual == nil)
    }
}
