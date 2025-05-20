import Combine
import Foundation

public struct Emission<State> {
    public enum Kind {
        case state
        case perform(work: @Sendable (State) async -> State)
        case observe(publisher: AnyPublisher<State, Never>)
    
    }

    let kind: Kind

    public static var state: Emission {
        Emission(kind: .state)
    }
    
//    public static func perform(
//        work: @Sendable @escaping (State) async -> State,
//        prepending: @Sendable @escaping (inout State) -> Void
//    ) -> Emission {
//        Emission(kind: .perform(work: work, prepending: prepending))
//    }
    
    public static func perform(
        work: @Sendable @escaping (State) async -> State
    ) -> Emission {
        Emission(kind: .perform(work: work))
    }
    
    public static func observe(
        _ publisher: AnyPublisher<State, Never>
    ) -> Emission {
        Emission(kind: .observe(publisher: publisher))
    }
}
