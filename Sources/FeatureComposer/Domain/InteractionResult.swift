import Foundation

public struct InteractionResult<State> {
    public enum Emission {
        case state
        case perform(
            work: @Sendable (State) async -> State,
            prepending: @Sendable (inout State) -> Void
        )
    }

    let emission: Emission

    public static var state: InteractionResult {
        InteractionResult(emission: .state)
    }
    
    public static func perform(
        work: @Sendable @escaping (State) async -> State,
        prepending: @Sendable @escaping (inout State) -> Void
    ) -> InteractionResult {
        InteractionResult(emission: .perform(work: work, prepending: prepending))
    }
    
    public static func perform(
        work: @Sendable @escaping (State) async -> State
    ) -> InteractionResult {
        InteractionResult(emission: .perform(work: work, prepending: { _ in }))
    }
}
