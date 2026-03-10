import Foundation

@MainActor
final class FeatureRuntime<State: Sendable, Action: Sendable> {
    enum ActionSource: Sendable {
        case sent
        case emitted
    }

    struct Step: Sendable {
        let action: Action
        let source: ActionSource
        let previousState: State
        let currentState: State
    }

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
        let previousState = state
        let emission = interactor.interact(state: &state, action: action)

        onStep?(
            Step(
                action: action,
                source: source,
                previousState: previousState,
                currentState: state
            )
        )

        let spawnedTasks = spawnTasks(from: emission)
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

    private func spawnTasks(from emission: Emission<Action>) -> [UUID: Task<Void, Never>] {
        switch emission.kind {
        case .none:
            return [:]

        case .action(let action):
            _ = send(action, source: .emitted)
            return [:]

        case .perform(let work):
            let uuid = UUID()
            let task = Task { [weak self] in
                guard let action = await work() else { return }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    _ = self.send(action, source: .emitted)
                }
            }
            return [uuid: task]

        case .observe(let stream):
            let uuid = UUID()
            let task = Task { [weak self] in
                for await action in await stream() {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        guard let self else { return }
                        _ = self.send(action, source: .emitted)
                    }
                }
            }
            return [uuid: task]

        case .merge(let emissions):
            return emissions.reduce(into: [:]) { result, emission in
                result.merge(spawnTasks(from: emission)) { _, new in new }
            }

        case .append(let emissions):
            guard !emissions.isEmpty else { return [:] }

            let uuid = UUID()
            let task = Task { @MainActor [weak self] in
                for emission in emissions {
                    guard !Task.isCancelled, let self else { return }

                    let childTasks = self.spawnTasks(from: emission)
                    guard !childTasks.isEmpty else { continue }

                    let childTaskIDs = Array(childTasks.keys)
                    self.taskRegistry.insert(childTasks)

                    let childTaskList = Array(childTasks.values)
                    await withTaskCancellationHandler {
                        await withTaskGroup(of: Void.self) { group in
                            for task in childTaskList {
                                group.addTask { await task.value }
                            }
                        }
                    } onCancel: {
                        for task in childTaskList {
                            task.cancel()
                        }
                    }

                    self.taskRegistry.remove(childTaskIDs)
                }
            }

            return [uuid: task]
        }
    }

    deinit {
        taskRegistry.cancelAll()
    }
}
