import Combine
import Foundation

extension Publisher where Failure == Never {
    /// Observes changes in `State` via `handler`. Imperative, synchronous updates are published
    /// immediately. Asynchronous updates (either via an async block or some observation mechanism) are
    /// folded back into `State` via a `CurrentValueSubject`
    func feedback<State>(
        initialState: State,
        handler: @escaping (inout State, Output) -> Emission<State>
    ) -> Publishers.HandleEvents<CurrentValueSubject<State, Never>> {
        let state = CurrentValueSubject<State, Never>(initialState)
        var effectCancellables = Set<AnyCancellable>()
        
        let upstreamCancellable = self.sink(
            receiveCompletion: { completion in
                state.send(completion: completion)
                effectCancellables.forEach { $0.cancel() }
            },
            receiveValue: { event in
                var current = state.value
                let emission = handler(&current, event)

                switch emission.kind {
                case .state:
                    state.value = current
                case .perform(let work):
                    Publishers.Async(work)
                        .sink { newState in state.value = newState }
                        .store(in: &effectCancellables)
                case .observe(let createPublisher):
                    createPublisher(DynamicState(stream: state))
                        .sink { newState in state.value = newState }
                        .store(in: &effectCancellables)
                }
            }
        )
        upstreamCancellable.store(in: &effectCancellables)
        
        return state
            .handleEvents(receiveCancel: {
                effectCancellables.forEach { $0.cancel() }
                upstreamCancellable.cancel()
            })
    }
}
