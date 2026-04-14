import Foundation

final class EffectTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [EffectID: Task<Void, Never>] = [:]

    func insert(_ tasks: [EffectID: Task<Void, Never>]) {
        guard !tasks.isEmpty else { return }

        lock.lock()
        self.tasks.merge(tasks) { _, new in new }
        lock.unlock()
    }

    func remove(_ ids: some Sequence<EffectID>) {
        lock.lock()
        for id in ids {
            tasks[id] = nil
        }
        lock.unlock()
    }

    func cancelAll() {
        let taskSnapshot: [Task<Void, Never>] = lock.withLock {
            Array(tasks.values)
        }

        for task in taskSnapshot {
            task.cancel()
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
