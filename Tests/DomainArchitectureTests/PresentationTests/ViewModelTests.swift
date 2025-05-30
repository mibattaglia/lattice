import Combine
import CombineSchedulers
import Foundation
import Testing

@testable import DomainArchitecture

@MainActor
@Suite
struct ViewModelTests {
    private let interactor: MyInteractor
    private let viewStateReducer: MyViewStateReducer
    private let viewModel: AnyViewModel<MyEvent, MyViewState>
    private let scheduler: TestSchedulerOf<DispatchQueue>

    private static let now = Date(timeIntervalSince1970: 1_748_377_205)

    init() {
        self.interactor = MyInteractor(dateFactory: { Self.now })
        self.viewStateReducer = MyViewStateReducer()
        self.scheduler = DispatchQueue.test
        self.viewModel = MyViewModel(
            scheduler: scheduler.eraseToAnyScheduler(),
            interactor: interactor.eraseToAnyInteractor(),
            viewStateReducer: viewStateReducer.eraseToAnyReducer()
        )
        .erased()
    }

    @Test
    func testBasics() async {
        let initialViewState = MyViewState.loading
        #expect(viewModel.viewState == initialViewState)

        viewModel.sendViewEvent(.load)
        await scheduler.advance()
        #expect(viewModel.viewState == viewStateFactory(count: 0))

        viewModel.sendViewEvent(.incrementCount)
        await scheduler.advance()
        #expect(viewModel.viewState == viewStateFactory(count: 1))

        viewModel.sendViewEvent(.incrementCount)
        await scheduler.advance()
        #expect(viewModel.viewState == viewStateFactory(count: 2))
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
