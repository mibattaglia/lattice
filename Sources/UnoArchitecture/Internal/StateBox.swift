import Foundation

@MainActor
final class StateBox<State>: @unchecked Sendable {
    var value: State

    init(_ initial: State) {
        self.value = initial
    }
}
