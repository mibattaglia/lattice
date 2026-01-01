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

        let actual = inputs.map { domainState -> MyViewState in
            var viewState: MyViewState = .loading
            myReducer.reduce(domainState, into: &viewState)
            return viewState
        }
        #expect(actual == expected)
    }

    @Test
    func reduceLoading() {
        var viewState: MyViewState = .error(title: "initial")
        myReducer.reduce(.loading, into: &viewState)
        #expect(viewState == .loading)
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

        var viewState: MyViewState = .loading
        myReducer.reduce(input, into: &viewState)
        #expect(viewState == expected)
    }
}
