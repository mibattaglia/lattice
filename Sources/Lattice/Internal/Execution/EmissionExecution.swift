import Foundation

@MainActor
enum EmissionExecution {
    static func spawnTasks<Action: Sendable>(
        from emission: Emission<Action>,
        rootScopeID: SendScopeID,
        cancellationRegistry: EffectCancellationRegistry,
        makeEffectID: @escaping @Sendable () -> EffectID,
        effectDidStart: @MainActor @escaping (EffectID) -> Void,
        effectDidComplete: @MainActor @escaping (EffectID) -> Void,
        effectDidCancel: @MainActor @escaping (EffectID) -> Void,
        enqueueEmittedAction: @MainActor @escaping (Action, SendScopeID) -> Void
    ) -> [EffectID: Task<Void, Never>] {
        spawnTasks(
            from: emission,
            rootScopeID: rootScopeID,
            effectCancellationRegistry: cancellationRegistry,
            makeEffectID: makeEffectID,
            effectDidStart: effectDidStart,
            effectDidComplete: effectDidComplete,
            effectDidCancel: effectDidCancel,
            enqueueEmittedAction: enqueueEmittedAction
        )
    }

    static func spawnTasks<Action: Sendable>(
        from emission: Emission<Action>,
        rootScopeID: SendScopeID,
        effectCancellationRegistry: EffectCancellationRegistry,
        makeEffectID: @escaping @Sendable () -> EffectID,
        effectDidStart: @MainActor @escaping (EffectID) -> Void,
        effectDidComplete: @MainActor @escaping (EffectID) -> Void,
        effectDidCancel: @MainActor @escaping (EffectID) -> Void,
        enqueueEmittedAction: @MainActor @escaping (Action, SendScopeID) -> Void
    ) -> [EffectID: Task<Void, Never>] {
        switch emission.kind {
        case .none:
            return [:]

        case .action(let action):
            enqueueEmittedAction(action, rootScopeID)
            return [:]

        case .perform(let work):
            guard let debounce = emission.executionOptions?.debounce else {
                return makeTrackedTask(
                    effectID: makeEffectID(),
                    effectDidStart: effectDidStart,
                    effectDidComplete: effectDidComplete,
                    effectDidCancel: effectDidCancel
                ) {
                    guard let action = await work() else { return }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        enqueueEmittedAction(action, rootScopeID)
                    }
                }
            }

            let effectID = makeEffectID()
            effectDidStart(effectID)

            let taskID = UUID()

            let task = Task { @MainActor in
                defer {
                    effectCancellationRegistry.removeCurrentTask(
                        taskID,
                        for: debounce.token
                    )
                }

                do {
                    try await debounce.sleep()
                } catch {
                    // Cancellation during the debounce sleep is expected.
                }

                guard !Task.isCancelled else {
                    effectDidCancel(effectID)
                    return
                }

                guard let action = await work() else {
                    if Task.isCancelled {
                        effectDidCancel(effectID)
                    } else {
                        effectDidComplete(effectID)
                    }
                    return
                }

                guard !Task.isCancelled else {
                    effectDidCancel(effectID)
                    return
                }

                await MainActor.run {
                    enqueueEmittedAction(action, rootScopeID)
                }

                if Task.isCancelled {
                    effectDidCancel(effectID)
                } else {
                    effectDidComplete(effectID)
                }
            }

            let trackedTask = EffectCancellationRegistry.TrackedTask(id: taskID, task: task)
            _ = effectCancellationRegistry.replace(
                trackedTask,
                for: debounce.token
            )

            return [effectID: task]

        case .observe(let stream):
            return makeTrackedTask(
                effectID: makeEffectID(),
                effectDidStart: effectDidStart,
                effectDidComplete: effectDidComplete,
                effectDidCancel: effectDidCancel
            ) {
                let actionStream = await stream()

                for await action in actionStream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        enqueueEmittedAction(action, rootScopeID)
                    }
                }
            }

        case .merge(let emissions):
            return emissions.reduce(into: [:]) { result, childEmission in
                result.merge(
                    spawnTasks(
                        from: childEmission,
                        rootScopeID: rootScopeID,
                        effectCancellationRegistry: effectCancellationRegistry,
                        makeEffectID: makeEffectID,
                        effectDidStart: effectDidStart,
                        effectDidComplete: effectDidComplete,
                        effectDidCancel: effectDidCancel,
                        enqueueEmittedAction: enqueueEmittedAction
                    )
                ) { _, new in new }
            }

        case .append(let emissions):
            guard !emissions.isEmpty else { return [:] }

            return makeTrackedTask(
                effectID: makeEffectID(),
                effectDidStart: effectDidStart,
                effectDidComplete: effectDidComplete,
                effectDidCancel: effectDidCancel
            ) {
                for childEmission in emissions {
                    guard !Task.isCancelled else { return }

                    let childTasks = spawnTasks(
                        from: childEmission,
                        rootScopeID: rootScopeID,
                        effectCancellationRegistry: effectCancellationRegistry,
                        makeEffectID: makeEffectID,
                        effectDidStart: { _ in },
                        effectDidComplete: { _ in },
                        effectDidCancel: { _ in },
                        enqueueEmittedAction: enqueueEmittedAction
                    )
                    let childTaskList = Array(childTasks.values)

                    guard !childTaskList.isEmpty else { continue }

                    await withTaskCancellationHandler {
                        await awaitAll(childTaskList)
                    } onCancel: {
                        for childTask in childTaskList {
                            childTask.cancel()
                        }
                    }
                }
            }
        }
    }

    private static func makeTrackedTask(
        effectID: EffectID,
        effectDidStart: @MainActor @escaping (EffectID) -> Void,
        effectDidComplete: @MainActor @escaping (EffectID) -> Void,
        effectDidCancel: @MainActor @escaping (EffectID) -> Void,
        operation: @MainActor @escaping @Sendable () async -> Void
    ) -> [EffectID: Task<Void, Never>] {
        effectDidStart(effectID)

        let task = Task { @MainActor in
            await operation()

            if Task.isCancelled {
                effectDidCancel(effectID)
            } else {
                effectDidComplete(effectID)
            }
        }

        return [effectID: task]
    }

    private static func awaitAll(_ tasks: some Sequence<Task<Void, Never>>) async {
        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask {
                    await task.value
                }
            }
        }
    }
}
