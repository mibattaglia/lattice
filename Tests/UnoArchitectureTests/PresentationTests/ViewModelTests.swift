import Foundation
import Testing

@testable import UnoArchitecture

@MainActor
@Suite
struct ViewModelTests {
    private let interactor: MyInteractor
    private let viewStateReducer: MyViewStateReducer
    private let viewModel: ViewModel<MyEvent, MyDomainState, MyViewState>

    private static let now = Date(timeIntervalSince1970: 1_748_377_205)

    init() {
        let capturedNow = Self.now
        self.interactor = MyInteractor(dateFactory: { capturedNow })
        self.viewStateReducer = MyViewStateReducer()
        self.viewModel = ViewModel(
            initialValue: .loading,
            interactor.eraseToAnyInteractorUnchecked(),
            viewStateReducer.eraseToAnyReducer()
        )
    }

    @Test
    func testBasics() async throws {
        let initialViewState = MyViewState.loading
        #expect(viewModel.viewState == initialViewState)

        viewModel.sendViewEvent(.load)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.viewState == viewStateFactory(count: 0))

        viewModel.sendViewEvent(.incrementCount)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.viewState == viewStateFactory(count: 1))
    }

    private func viewStateFactory(count: Int) -> MyViewState {
        MyViewState.success(
            .init(
                count: count,
                dateDisplayString: "4:20 PM",
                isLoading: false
            )
        )
    }
}
