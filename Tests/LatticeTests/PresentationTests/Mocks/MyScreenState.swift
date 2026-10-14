import CasePaths
import Foundation
import Lattice

@CasePathable
@FeatureState
enum MyScreenState: Equatable, Sendable {
    case loading
    case error(code: Int)
    case success(MyContentState)

    /// The message views show for `.error`, derived from the code.
    var errorTitle: String? {
        guard case .error(let code) = self else { return nil }
        switch code {
        case 500...599:
            return "Please check your internet and try again."
        case 400...499:
            return "Something went wrong, please try again."
        default:
            return "Unknown error."
        }
    }
}
