extension Task where Failure == Never {
    /// Starts `operation` now, on the caller's isolation: it runs to its first suspension before
    /// this returns, then resumes on that isolation after every `await`. On OS 26 this is
    /// `Task.immediate`; before that, `startOnMainActor` on the main actor, and elsewhere a plain
    /// `Task`, which starts later, as a job on the operation's isolation.
    ///
    /// The signature carries the guarantee: `isolation` defaults to `#isolation`, and `operation` is
    /// `sending @escaping @isolated(any)` under `@_inheritActorContext(always)`, so a closure formed
    /// in an isolated context keeps that isolation after its first suspension.
    static func immediateIfAvailable(
        isolation: (any Actor)? = #isolation,
        @_inheritActorContext(always) operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            Task.immediate(operation: operation)
        } else if isolation === MainActor.shared {
            MainActor.assumeIsolated {
                Task.startOnMainActor { await operation() }
            }
        } else {
            Task(operation: operation)
        }
    }
}

extension [Task<Void, Never>] {
    /// One task that waits for every task in the array and cancels them when it is cancelled, or
    /// `nil` for an empty array.
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
