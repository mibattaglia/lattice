import Foundation

final class EffectTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var taskIDsByOriginID: [UUID: Set<UUID>] = [:]
    private var cancelledOriginIDs: Set<UUID> = []

    func insert(
        task: Task<Void, Never>,
        taskID: UUID,
        originID: UUID
    ) {
        lock.withLock {
            tasks[taskID] = task
            taskIDsByOriginID[originID, default: []].insert(taskID)
        }
    }

    func remove(taskID: UUID, originID: UUID) {
        lock.withLock {
            tasks[taskID] = nil
            taskIDsByOriginID[originID]?.remove(taskID)
            if taskIDsByOriginID[originID]?.isEmpty == true {
                taskIDsByOriginID[originID] = nil
            }
        }
    }

    func cancel(taskID: UUID) {
        let task = lock.withLock {
            tasks[taskID]
        }
        task?.cancel()
    }

    func cancel(originID: UUID) {
        let originTasks: [Task<Void, Never>] = lock.withLock {
            cancelledOriginIDs.insert(originID)
            let taskIDs = taskIDsByOriginID[originID] ?? []
            return taskIDs.compactMap { tasks[$0] }
        }

        for task in originTasks {
            task.cancel()
        }
    }

    func cancelAll() {
        let taskSnapshot: [Task<Void, Never>] = lock.withLock {
            cancelledOriginIDs.formUnion(taskIDsByOriginID.keys)
            return Array(tasks.values)
        }

        for task in taskSnapshot {
            task.cancel()
        }
    }

    func isCancelled(originID: UUID) -> Bool {
        lock.withLock {
            cancelledOriginIDs.contains(originID)
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
