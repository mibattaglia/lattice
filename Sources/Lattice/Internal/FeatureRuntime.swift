import Foundation

@MainActor
final class FeatureRuntime<State: Sendable, Action: Sendable> {
    typealias Step = ActionTransition<State, Action>

    private(set) var onStep: (@MainActor (Step) -> Void)?

    private(set) var state: State

    private let interactor: AnyInteractor<State, Action>
    private nonisolated let taskRegistry: EffectTaskRegistry

    init(
        initialState: State,
        interactor: AnyInteractor<State, Action>,
        taskRegistry: EffectTaskRegistry = EffectTaskRegistry()
    ) {
        self.state = initialState
        self.interactor = interactor
        self.taskRegistry = taskRegistry
    }

    func setStepHandler(_ handler: @escaping (@MainActor (Step) -> Void)) {
        self.onStep = handler
    }

    @discardableResult
    func send(_ action: Action, source: ActionSource = .sent) -> EventTask {
        send(action, source: source, rootScopeID: SendScopeID())
    }

    @discardableResult
    private func send(
        _ action: Action,
        source: ActionSource,
        rootScopeID: SendScopeID
    ) -> EventTask {
        var updatedState = state
        let transition = ActionTransition.apply(
            action,
            source: source,
            rootScopeID: rootScopeID,
            to: &updatedState,
            using: interactor
        )
        state = transition.currentState

        onStep?(transition)

        let spawnedTasks = EmissionExecution.spawnTasks(
            from: transition.emission,
            rootScopeID: rootScopeID,
            makeEffectID: { EffectID() },
            effectDidStart: { _ in },
            effectDidComplete: { _ in },
            effectDidCancel: { _ in },
            enqueueEmittedAction: { [weak self] action, rootScopeID in
                guard let self else { return }
                _ = self.send(action, source: .emitted, rootScopeID: rootScopeID)
            }
        )
        taskRegistry.insert(spawnedTasks)

        guard !spawnedTasks.isEmpty else {
            return EventTask(rawValue: nil)
        }

        let spawnedTaskIDs = Array(spawnedTasks.keys)
        let taskList = Array(spawnedTasks.values)
        let compositeTask = Task { [weak self] in
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    for task in taskList {
                        group.addTask { await task.value }
                    }
                }
            } onCancel: {
                for task in taskList {
                    task.cancel()
                }
            }
            self?.taskRegistry.remove(spawnedTaskIDs)
        }

        return EventTask(rawValue: compositeTask)
    }

    nonisolated func cancelAllEffects() {
        taskRegistry.cancelAll()
    }

    deinit {
        taskRegistry.cancelAll()
    }
}
