import Combine
import UnoArchitecture
import Foundation
import Testing

@Suite
final class ViewStateReducerTests {
    private var cancellables: Set<AnyCancellable> = []
    private let subject = PassthroughSubject<MyDomainState, Never>()
    private let myReducer = MyViewStateReducer()

    @Test
    func reduceError() async {
        let expected: [MyViewState] = [
            .error(title: "Please check your internet and try again."),
            .error(title: "Something went wrong, please try again."),
            .error(title: "Unknown error."),
        ]

        await confirmation { confirmation in
            myReducer.reduce(subject.eraseToAnyPublisher())
                .collect()
                .sink { actual in
                    #expect(actual == expected)
                    confirmation()
                }
                .store(in: &cancellables)

            subject.send(.error(code: 503))
            subject.send(.error(code: 404))
            subject.send(.error(code: 123))
            subject.send(completion: .finished)
        }
    }

    @Test
    func reduceLoading() async {
        await confirmation { confirmation in
            myReducer.reduce(subject.eraseToAnyPublisher())
                .sink { actual in
                    #expect(actual == .loading)
                    confirmation()
                }
                .store(in: &cancellables)

            subject.send(.loading)
            subject.send(completion: .finished)
        }
    }

    @Test
    func reduceSuccess() async {
        let expected = MyViewState.success(
            .init(
                count: 12,
                dateDisplayString: "4:20 PM",
                isLoading: false
            )
        )
        await confirmation { confirmation in
            myReducer.reduce(subject.eraseToAnyPublisher())
                .sink { actual in
                    #expect(actual == expected)
                    confirmation()
                }
                .store(in: &cancellables)

            subject.send(
                .success(
                    .init(
                        count: 12,
                        timestamp: 1_748_377_205,
                        isLoading: false
                    )
                )
            )
            subject.send(completion: .finished)
        }
    }
}
