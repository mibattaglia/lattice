import Foundation

struct UncheckedSendable<T>: @unchecked Sendable {
    nonisolated(unsafe) let item: T
}
