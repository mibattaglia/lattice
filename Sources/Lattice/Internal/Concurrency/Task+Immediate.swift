// Copied from TCA 2 (`ComposableArchitecture2/Internal/Task.swift`), re-indented. The
// `immediateIfAvailable` overloads are internal instead of `package`: the CocoaPods build passes no
// `-package-name`, and `package` declarations do not compile without one.

extension Task where Failure == Never {
    @discardableResult
    static func immediateIfAvailable(
        name: String? = nil,
        priority: TaskPriority? = nil,
        isolation: (any Actor)? = #isolation,
        @_implicitSelfCapture @_inheritActorContext(always)
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            Task.immediate(name: name, priority: priority, operation: operation)
        } else if isolation === MainActor.shared {
            MainActor.assumeIsolated {
                Task.startOnMainActor(priority: priority) {
                    await operation()
                }
            }
        } else {
            Task(name: name, priority: priority, operation: operation)
        }
    }
}

extension Task where Failure == any Error {
    @discardableResult
    static func immediateIfAvailable(
        name: String? = nil,
        priority: TaskPriority? = nil,
        isolation: (any Actor)? = #isolation,
        @_implicitSelfCapture @_inheritActorContext(always)
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Failure> {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            Task.immediate(name: name, priority: priority, operation: operation)
        } else if isolation === MainActor.shared {
            MainActor.assumeIsolated {
                Task.startOnMainActor(priority: priority) {
                    try await operation()
                }
            }
        } else {
            Task(name: name, priority: priority, operation: operation)
        }
    }
}

extension ThrowingTaskGroup {
    mutating func addImmediateTaskIfAvailable(
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async throws -> ChildTaskResult
    ) {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            addImmediateTask(
                name: name,
                priority: priority,
                operation: operation
            )
        } else {
            addTask(
                name: name,
                priority: priority,
                operation: operation
            )
        }
    }
}

extension [Task<Void, Never>] {
    var all: Task<Void, Never>? {
        guard !isEmpty else { return nil }
        return Task.immediateIfAvailable {
            await withTaskCancellationHandler {
                for task in self {
                    await task.value
                }
            } onCancel: {
                for task in self {
                    task.cancel()
                }
            }
        }
    }
}
