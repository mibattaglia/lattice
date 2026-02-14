import Foundation
import Testing

@testable import Lattice

@MainActor
@Suite
struct ViewModelTests {
    private let interactor: MyInteractor
    private let viewStateReducer: MyViewStateReducer
    private let viewModel: ViewModel<Feature<MyEvent, MyDomainState, MyViewState>>

    private static let now = Date(timeIntervalSince1970: 1_748_377_205)

    init() {
        let capturedNow = Self.now
        self.interactor = MyInteractor(dateFactory: { capturedNow })
        self.viewStateReducer = MyViewStateReducer()
        let feature = Feature(
            interactor: interactor.eraseToAnyInteractorUnchecked(),
            reducer: viewStateReducer
        )
        self.viewModel = ViewModel(
            initialDomainState: .loading,
            feature: feature
        )
    }

    @Test
    func testSynchronousActions() {
        let initialViewState = MyViewState.loading
        #expect(viewModel.viewState == initialViewState)

        viewModel.sendViewEvent(.load)
        #expect(viewModel.viewState == viewStateFactory(count: 0))

        viewModel.sendViewEvent(.incrementCount)
        #expect(viewModel.viewState == viewStateFactory(count: 1))
    }

    @Test
    func testAsyncEffectAwaiting() async {
        viewModel.sendViewEvent(.load)
        #expect(viewModel.viewState == viewStateFactory(count: 0))

        let eventTask = viewModel.sendViewEvent(.fetchData)

        // Synchronous state update happens immediately (isLoading = true)
        #expect(viewModel.viewState == viewStateFactory(count: 0, isLoading: true))

        // Await the effect to complete
        await eventTask.finish()

        // Async effect has completed (count = 42, isLoading = false)
        #expect(viewModel.viewState == viewStateFactory(count: 42, isLoading: false))
    }

    private func viewStateFactory(count: Int, isLoading: Bool = false) -> MyViewState {
        MyViewState.success(
            .init(
                count: count,
                dateDisplayString: "8:20 PM",
                isLoading: isLoading
            )
        )
    }
}
