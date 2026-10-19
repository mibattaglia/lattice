import Foundation
import Testing

@testable import Lattice

@MainActor
@Suite
struct ViewModelTests {
    private let interactor: MyInteractor
    private let viewModel: ViewModel<Feature<MyEvent, MyScreenState>>

    private static let now = Date(timeIntervalSince1970: 1_748_377_205)

    init() {
        let capturedNow = Self.now
        self.interactor = MyInteractor(dateFactory: { capturedNow })
        let feature = Feature(interactor: interactor.eraseToAnyInteractor())
        self.viewModel = ViewModel(
            initialState: .loading,
            feature: feature
        )
    }

    @Test
    func testSynchronousActions() {
        #expect(viewModel.viewState == .loading)

        viewModel.sendViewEvent(.load)
        #expect(viewModel.viewState == viewStateFactory(count: 0))
        // The formatter separates the time and "PM" with a narrow no-break space.
        #expect(viewModel.viewState[case: \.success]?.dateDisplayString == "8:20\u{202F}PM")

        viewModel.sendViewEvent(.incrementCount)
        #expect(viewModel.viewState == viewStateFactory(count: 1))
    }

    @Test
    func testAsyncEffectAwaiting() async {
        viewModel.sendViewEvent(.load)
        #expect(viewModel.viewState == viewStateFactory(count: 0))

        let task = viewModel.sendViewEvent(.fetchData)

        // Synchronous state update happens immediately (isLoading = true)
        #expect(viewModel.viewState == viewStateFactory(count: 0, isLoading: true))

        // Await the effect to complete
        await task?.value

        // Async effect has completed (count = 42, isLoading = false)
        #expect(viewModel.viewState == viewStateFactory(count: 42, isLoading: false))
    }

    @Test
    func computedMembersDerivePresentationValues() {
        #expect(MyScreenState.ViewState(.error(code: 503)).errorTitle == "Please check your internet and try again.")
        #expect(MyScreenState.ViewState(.error(code: 404)).errorTitle == "Something went wrong, please try again.")
        #expect(MyScreenState.ViewState(.error(code: 123)).errorTitle == "Unknown error.")
        #expect(MyScreenState.ViewState(.loading).errorTitle == nil)
    }

    private func viewStateFactory(count: Int, isLoading: Bool = false) -> MyScreenState.ViewState {
        MyScreenState.ViewState(
            .success(
                MyContentState(
                    count: count,
                    timestamp: Self.now.timeIntervalSince1970,
                    isLoading: isLoading
                )
            )
        )
    }
}
