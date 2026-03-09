import Foundation

final class EmissionRuntime<Action: Sendable> {
    typealias ActionHandler = @MainActor (Action) -> Emission<Action>

    private let handleAction: ActionHandler
    private var effectTasks: [UUID: Task<Void, Never>] = [:]

    init(handleAction: @escaping ActionHandler) {
        self.handleAction = handleAction
    }

    @MainActor
    func send(_ action: Action) -> EventTask {
        let emission = handleAction(action)
        return run(emission)
    }

    @MainActor
    func run(_ emission: Emission<Action>) -> EventTask {
        let spawnedTasks = spawnTasks(from: emission)
        let spawnedUUIDs = Set(spawnedTasks.keys)
        register(spawnedTasks)

        guard !spawnedTasks.isEmpty else {
            return EventTask(rawValue: nil)
        }

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
            await MainActor.run {
                self?.removeTasks(withIDs: spawnedUUIDs)
            }
        }

        return EventTask(rawValue: compositeTask)
    }

    func cancelAll() {
        for task in effectTasks.values {
            task.cancel()
        }
    }

    @MainActor
    private func register(_ spawnedTasks: [UUID: Task<Void, Never>]) {
        effectTasks.merge(spawnedTasks) { _, new in new }
    }

    @MainActor
    private func removeTasks(withIDs ids: some Sequence<UUID>) {
        for id in ids {
            effectTasks[id] = nil
        }
    }

    @MainActor
    private func spawnTasks(from emission: Emission<Action>) -> [UUID: Task<Void, Never>] {
        switch emission.kind {
        case .none:
            return [:]

        case .action(let action):
            let innerEmission = handleAction(action)
            return spawnTasks(from: innerEmission)

        case .perform(let work):
            let uuid = UUID()
            let task = Task { [weak self] in
                guard let action = await work() else { return }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    let emission = self.handleAction(action)
                    self.register(self.spawnTasks(from: emission))
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
                        let emission = self.handleAction(action)
                        self.register(self.spawnTasks(from: emission))
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

                    let childUUIDs = Set(childTasks.keys)
                    self.register(childTasks)

                    let childList = Array(childTasks.values)
                    await withTaskCancellationHandler {
                        await withTaskGroup(of: Void.self) { group in
                            for task in childList {
                                group.addTask { await task.value }
                            }
                        }
                    } onCancel: {
                        for task in childList {
                            task.cancel()
                        }
                    }

                    self.removeTasks(withIDs: childUUIDs)
                }
            }
            return [uuid: task]
        }
    }

    deinit {
        cancelAll()
    }
}
