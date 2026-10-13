import Foundation
import Lattice

@FeatureState
struct MyContentState: Equatable, Sendable {
    var count: Int
    @Domain var timestamp: TimeInterval
    var isLoading: Bool

    /// The time views show for the hidden `timestamp`.
    var dateDisplayString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = .gmt
        formatter.locale = .init(identifier: "en_us")
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
