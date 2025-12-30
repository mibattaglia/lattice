import AsyncAlgorithms
import Foundation

/// A primitive used *inside* an ``Interactor``'s ``Interactor/body-swift.property`` for
/// handling incoming **actions** and emitting new **state** via an ``Emission``.
//@MainActor
public struct Interact<State: Sendable, Action: Sendable>: Interactor, @unchecked Sendable {
    public typealias Handler = @MainActor (inout State, Action) -> Emission<State>

    private let initialValue: State
    private let handler: Handler

    public init(initialValue: State, handler: @escaping Handler) {
        self.initialValue = initialValue
        self.handler = handler
    }

    public var body: some Interactor<State, Action> { self }

    public func interact(_ upstream: AsyncStream<Action>) -> AsyncStream<State> {
        let initialValue = self.initialValue
        let handler = self.handler

        return AsyncStream { continuation in
            let task = Task { @MainActor in
                let stateBox = StateBox(initialValue)
                var effectTasks: [Task<Void, Never>] = []

                let send = Send<State> { newState in
                    stateBox.value = newState
                    continuation.yield(newState)
                }

                continuation.yield(stateBox.value)

                for await action in upstream {
                    var state = stateBox.value
                    let emission = handler(&state, action)
                    stateBox.value = state

                    switch emission.kind {
                    case .state:
                        continuation.yield(state)

                    case .perform(let work):
                        let dynamicState = DynamicState {
                            await MainActor.run { stateBox.value }
                        }
                        let effectTask = Task {
                            await work(dynamicState, send)
                        }
                        effectTasks.append(effectTask)

                    case .observe(let streamWork):
                        let dynamicState = DynamicState {
                            await MainActor.run { stateBox.value }
                        }
                        let effectTask = Task {
                            await streamWork(dynamicState, send)
                        }
                        effectTasks.append(effectTask)
                    }
                }

                effectTasks.forEach { $0.cancel() }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
