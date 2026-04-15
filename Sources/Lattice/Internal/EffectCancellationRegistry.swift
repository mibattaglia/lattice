import Foundation
import os

internal final class EffectCancellationRegistry: Sendable {
    internal struct TrackedTask: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let tasks = OSAllocatedUnfairLock(initialState: [DebounceToken: TrackedTask]())

    internal init() {}

    internal func replace(
        _ task: TrackedTask,
        for token: DebounceToken
    ) -> TrackedTask? {
        let previous = tasks.withLock { state in
            state.updateValue(task, forKey: token)
        }

        previous?.task.cancel()
        return previous
    }

    internal func removeCurrentTask(
        _ taskID: UUID,
        for token: DebounceToken
    ) {
        tasks.withLock { state in
            guard state[token]?.id == taskID else { return }
            state[token] = nil
        }
    }

    internal func cancelAll() {
        let tasksToCancel = tasks.withLock { state in
            let tasksToCancel = Array(state.values.map(\.task))
            state.removeAll()
            return tasksToCancel
        }

        for task in tasksToCancel {
            task.cancel()
        }
    }
}
