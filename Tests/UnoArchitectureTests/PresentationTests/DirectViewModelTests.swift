import Foundation
import Testing

@testable import UnoArchitecture

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
        Interact(initialValue: FeatureState()) { state, event in
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
        self.viewModel = DirectViewModel(.init(), interactor.eraseToAnyInteractor())
    }

    @Test
    func directViewModel() async throws {
        #expect(viewModel.viewState == FeatureState())

        viewModel.sendViewEvent(.incrementCount)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.viewState == FeatureState(count: 1))
        viewModel.sendViewEvent(.incrementCount)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.viewState == FeatureState(count: 2))

        viewModel.sendViewEvent(.decrementCount)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.viewState == FeatureState(count: 1))

        viewModel.sendViewEvent(.increaseAge)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.viewState == FeatureState(count: 1, age: 901))
    }
}
