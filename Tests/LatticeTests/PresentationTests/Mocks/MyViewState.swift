import Foundation
import Lattice

@ObservableState
enum MyViewState: Equatable {
    case loading
    case error(title: String)
    case success(Content)

    struct Content: Equatable {
        let count: Int
        let dateDisplayString: String
        let isLoading: Bool
    }
}
