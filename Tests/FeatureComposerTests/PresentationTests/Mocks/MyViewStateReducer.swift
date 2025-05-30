import FeatureComposer
import Foundation

struct MyViewStateReducer: ViewStateReducer {
    typealias DomainState = MyDomainState
    typealias ViewState = MyViewState

    var body: some ViewStateReducerOf<Self> {
        Self.build { domainState in
            switch domainState {
            case let .error(code):
                return .error(title: reduceErrorCode(code))
            case .loading:
                return .loading
            case let .success(content):
                return .success(reduceContent(content))
            }
        }
    }

    private func reduceErrorCode(_ code: Int) -> String {
        switch code {
        case 500...599:
            return "Please check your internet and try again."
        case 400...499:
            return "Something went wrong, please try again."
        default:
            return "Unknown error."
        }
    }

    private func reduceContent(_ domain: MyDomainState.Content) -> MyViewState.Content {
        MyViewState.Content(
            count: domain.count,
            dateDisplayString: formattedTime(domain.timestamp),
            isLoading: domain.isLoading
        )
    }

    private func formattedTime(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.locale = .init(identifier: "en_us")
        return formatter.string(from: date)
    }
}
