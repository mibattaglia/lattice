import Combine
import Foundation

public struct Emission<State> {
    public enum Kind {
        case state
        case perform(work: @Sendable () async -> State)
        case observe(publisher: (DynamicState<State>) -> AnyPublisher<State, Never>)
    
    }

    let kind: Kind

    public static var state: Emission {
        Emission(kind: .state)
    }
    
    public static func perform(
        work: @Sendable @escaping () async -> State
    ) -> Emission {
        Emission(kind: .perform(work: work))
    }
    
    public static func observe(
        _ builder: @escaping (DynamicState<State>) -> AnyPublisher<State, Never>
    ) -> Emission {
        Emission(kind: .observe(publisher: builder))
    }
}
