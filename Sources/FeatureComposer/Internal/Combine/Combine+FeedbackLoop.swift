import Combine
import Foundation

struct FeedbackState<State> {
    let state: State
    let emission: Emission<State>
}

extension Publisher where Failure == Never {
    func feedback<State>(
        initialState: State,
        handler: @escaping (inout State, Output) -> Emission<State>
    ) -> Publishers.FlatMap<AnyPublisher<State, Never>, Publishers.Scan<Self, FeedbackState<State>>> {
        feedbackAccumulator(initialState: initialState, handler: handler)
            .flatMap(effects(_:))
    }
    
    func feedbackFromLatest<State>(
        initialState: State,
        handler: @escaping (inout State, Output) -> Emission<State>
    ) -> Publishers.SwitchToLatest<AnyPublisher<State, Never>, Publishers.Map<Publishers.Scan<Self, FeedbackState<State>>, AnyPublisher<State, Never>>> {
        feedbackAccumulator(initialState: initialState, handler: handler)
            .map(effects(_:))
            .switchToLatest()
    }
    
    private func feedbackAccumulator<State>(
        initialState: State,
        handler: @escaping (inout State, Output) -> Emission<State>
    ) -> Publishers.Scan<Self, FeedbackState<State>> {
        scan(FeedbackState(state: initialState, emission: .state)) { accumulated, event in
            var state = accumulated.state
            let emission = handler(&state, event)
            return FeedbackState(state: state, emission: emission)
        }
    }
    
    private func effects<State>(
        _ feedbackState: FeedbackState<State>
    ) -> AnyPublisher<State, Never> {
        switch feedbackState.emission.kind {
        case .state:
            return Just(feedbackState.state)
                .eraseToAnyPublisher()
        case let .perform(work):
            // TODO: - Spin Up Async Publisher Here
            return Just(feedbackState.state)
                // .prepend(feedbackState.state)
                .eraseToAnyPublisher()
        case let .observe(publisher):
            return publisher
                .prepend(feedbackState.state)
                .eraseToAnyPublisher()
        }
    }
}
