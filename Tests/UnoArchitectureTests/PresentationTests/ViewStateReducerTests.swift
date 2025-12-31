import Foundation
import Testing
import UnoArchitecture

@Suite
@MainActor
struct ViewStateReducerTests {
    private let myReducer = MyViewStateReducer()

    @Test
    func reduceError() {
        let inputs: [MyDomainState] = [
            .error(code: 503),
            .error(code: 404),
            .error(code: 123),
        ]
        let expected: [MyViewState] = [
            .error(title: "Please check your internet and try again."),
            .error(title: "Something went wrong, please try again."),
            .error(title: "Unknown error."),
        ]

        let actual = inputs.map { myReducer.reduce($0) }
        #expect(actual == expected)
    }

    @Test
    func reduceLoading() {
        let actual = myReducer.reduce(.loading)
        #expect(actual == .loading)
    }

    @Test
    func reduceSuccess() {
        let input = MyDomainState.success(
            .init(
                count: 12,
                timestamp: 1_748_377_205,
                isLoading: false
            )
        )
        let expected = MyViewState.success(
            .init(
                count: 12,
                dateDisplayString: "4:20\u{202F}PM",
                isLoading: false
            )
        )

        let actual = myReducer.reduce(input)
        #expect(actual == expected)
    }
}
