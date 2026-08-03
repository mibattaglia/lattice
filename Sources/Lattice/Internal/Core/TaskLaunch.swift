extension Task where Failure == Never {
    /// Starts a task synchronously in the caller's isolation domain when the runtime allows:
    /// `Task.immediate` on OS 26+, the `Task.startOnMainActor` shim on iOS 17–25 for the
    /// MainActor, and a plain `Task` otherwise (the operation still *runs* isolated to the
    /// captured context via `@isolated(any)`; only the synchronous start is lost — acceptable
    /// because non-main hosting is an OS 26+ tier where `Task.immediate` exists).
    ///
    /// The synchronous in-domain start is what makes non-`@Sendable` effect operations safe to
    /// launch: the closure is invoked before control returns to the caller, in the same
    /// isolation domain, so captured non-Sendable state never crosses a boundary.
    @discardableResult
    static func immediateIfAvailable(
        priority: TaskPriority? = nil,
        isolation: (any Actor)? = #isolation,
        @_implicitSelfCapture @_inheritActorContext(always)
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            Task.immediate(priority: priority, operation: operation)
        } else if isolation === MainActor.shared {
            MainActor.assumeIsolated {
                Task.startOnMainActor(priority: priority) {
                    await operation()
                }
            }
        } else {
            Task(priority: priority, operation: operation)
        }
    }
}

extension Array where Element == Task<Void, Never> {
    /// Folds many tasks into one: awaiting the result awaits every task; cancelling it
    /// cancels every task. Backs the composite handle `send` returns for the effects an
    /// update launched.
    ///
    /// `Task` handles are `Sendable`, so no unsafe captures are needed here.
    func all() -> Task<Void, Never> {
        let tasks = self
        return Task {
            await withTaskCancellationHandler {
                for task in tasks {
                    await task.value
                }
            } onCancel: {
                for task in tasks {
                    task.cancel()
                }
            }
        }
    }
}
