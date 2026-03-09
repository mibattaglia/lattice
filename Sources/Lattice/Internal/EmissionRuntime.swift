import Foundation

enum EmissionRuntimeActionSource: Sendable {
    case sent(originID: UUID)
    case emitted(originID: UUID)

    var originID: UUID {
        switch self {
        case .sent(let originID), .emitted(let originID):
            return originID
        }
    }
}

struct EmissionRuntimeActionResult<Action: Sendable, BufferedStep: Sendable>: Sendable {
    let emission: Emission<Action>
    let bufferedStep: BufferedStep?

    init(
        emission: Emission<Action>,
        bufferedStep: BufferedStep? = nil
    ) {
        self.emission = emission
        self.bufferedStep = bufferedStep
    }
}

struct EmissionRuntimeSendResult: Sendable {
    let originID: UUID
    let eventTask: EventTask
}

final class EmissionRuntime<Action: Sendable, BufferedStep: Sendable>: @unchecked Sendable {
    typealias ActionHandler =
        @MainActor (Action, EmissionRuntimeActionSource) -> EmissionRuntimeActionResult<
            Action, BufferedStep
        >

    private let handleAction: ActionHandler
    private var effectTasks: [UUID: Task<Void, Never>] = [:]
    private var effectOrigins: [UUID: UUID] = [:]
    private var inFlightCountsByOrigin: [UUID: Int] = [:]
    private var bufferedStepsStorage: [BufferedStep] = []
    private var bufferedStepWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaitersByOrigin: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(handleAction: @escaping ActionHandler) {
        self.handleAction = handleAction
    }

    @MainActor
    var bufferedSteps: [BufferedStep] {
        bufferedStepsStorage
    }

    @MainActor
    func send(_ action: Action) -> EmissionRuntimeSendResult {
        let originID = UUID()
        let result = handleAction(action, .sent(originID: originID))
        return run(result.emission, originID: originID)
    }

    @MainActor
    func run(
        _ emission: Emission<Action>,
        originID: UUID
    ) -> EmissionRuntimeSendResult {
        let spawnedTasks = spawnTasks(from: emission, originID: originID)
        register(spawnedTasks, originID: originID)
        guard !spawnedTasks.isEmpty else {
            return EmissionRuntimeSendResult(
                originID: originID,
                eventTask: EventTask(rawValue: nil)
            )
        }

        let taskList = Array(spawnedTasks.values)
        let task = Task<Void, Never> {
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    for childTask in taskList {
                        group.addTask { await childTask.value }
                    }
                }
            } onCancel: {
                for childTask in taskList {
                    childTask.cancel()
                }
            }
        }

        return EmissionRuntimeSendResult(
            originID: originID,
            eventTask: EventTask(rawValue: task)
        )
    }

    @MainActor
    func popFirstBufferedStep() -> BufferedStep? {
        guard !bufferedStepsStorage.isEmpty else { return nil }
        return bufferedStepsStorage.removeFirst()
    }

    @MainActor
    func popAllBufferedSteps() -> [BufferedStep] {
        let steps = bufferedStepsStorage
        bufferedStepsStorage.removeAll()
        return steps
    }

    @MainActor
    func waitForBufferedStepCount(
        atLeast count: Int,
        timeout: Duration
    ) async -> Bool {
        if bufferedStepsStorage.count >= count {
            return true
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                while let self {
                    await self.waitForBufferedStepChange()
                    let hasEnoughSteps = await MainActor.run {
                        self.bufferedStepsStorage.count >= count
                    }
                    if hasEnoughSteps {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    @MainActor
    func waitForEffectsToDrain(originID: UUID) async {
        guard hasInFlightEffects(originID: originID) else { return }

        await withCheckedContinuation { continuation in
            drainWaitersByOrigin[originID, default: []].append(continuation)
        }
    }

    @MainActor
    func cancelEffects(originID: UUID) {
        for (effectID, task) in effectTasks where effectOrigins[effectID] == originID {
            task.cancel()
        }
    }

    @MainActor
    func hasInFlightEffects(originID: UUID) -> Bool {
        (inFlightCountsByOrigin[originID] ?? 0) > 0
    }

    private func cancelAll() {
        for task in effectTasks.values {
            task.cancel()
        }
    }

    @MainActor
    private func register(
        _ spawnedTasks: [UUID: Task<Void, Never>],
        originID: UUID
    ) {
        guard !spawnedTasks.isEmpty else {
            notifyIfOriginDrained(originID)
            return
        }

        effectTasks.merge(spawnedTasks) { _, new in new }
        for effectID in spawnedTasks.keys {
            effectOrigins[effectID] = originID
        }
        inFlightCountsByOrigin[originID, default: 0] += spawnedTasks.count
    }

    @MainActor
    private func removeTask(
        withID effectID: UUID,
        originID: UUID
    ) {
        effectTasks[effectID] = nil
        effectOrigins[effectID] = nil
        if let count = inFlightCountsByOrigin[originID] {
            let nextCount = count - 1
            if nextCount <= 0 {
                inFlightCountsByOrigin[originID] = nil
            } else {
                inFlightCountsByOrigin[originID] = nextCount
            }
        }
        notifyIfOriginDrained(originID)
    }

    @MainActor
    private func appendBufferedStep(_ step: BufferedStep) {
        bufferedStepsStorage.append(step)

        let waiters = bufferedStepWaiters
        bufferedStepWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    @MainActor
    private func notifyIfOriginDrained(_ originID: UUID) {
        guard !hasInFlightEffects(originID: originID) else { return }
        let waiters = drainWaitersByOrigin.removeValue(forKey: originID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    @MainActor
    private func waitForBufferedStepChange() async {
        await withCheckedContinuation { continuation in
            bufferedStepWaiters.append(continuation)
        }
    }

    @MainActor
    private func spawnTasks(
        from emission: Emission<Action>,
        originID: UUID
    ) -> [UUID: Task<Void, Never>] {
        switch emission.kind {
        case .none:
            return [:]

        case .action(let action):
            let result = handleAction(action, .emitted(originID: originID))
            if let step = result.bufferedStep {
                appendBufferedStep(step)
            }
            return spawnTasks(from: result.emission, originID: originID)

        case .perform(let work):
            let effectID = UUID()
            let task = Task { [weak self] in
                defer {
                    Task { @MainActor [weak self] in
                        self?.removeTask(withID: effectID, originID: originID)
                    }
                }

                guard let action = await work() else { return }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    let result = self.handleAction(action, .emitted(originID: originID))
                    if let step = result.bufferedStep {
                        self.appendBufferedStep(step)
                    }
                    self.register(
                        self.spawnTasks(from: result.emission, originID: originID),
                        originID: originID
                    )
                }
            }
            return [effectID: task]

        case .observe(let stream):
            let effectID = UUID()
            let task = Task { [weak self] in
                defer {
                    Task { @MainActor [weak self] in
                        self?.removeTask(withID: effectID, originID: originID)
                    }
                }

                for await action in await stream() {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        guard let self else { return }
                        let result = self.handleAction(action, .emitted(originID: originID))
                        if let step = result.bufferedStep {
                            self.appendBufferedStep(step)
                        }
                        self.register(
                            self.spawnTasks(from: result.emission, originID: originID),
                            originID: originID
                        )
                    }
                }
            }
            return [effectID: task]

        case .merge(let emissions):
            return emissions.reduce(into: [:]) { result, emission in
                result.merge(spawnTasks(from: emission, originID: originID)) { _, new in new }
            }

        case .append(let emissions):
            guard !emissions.isEmpty else { return [:] }

            let effectID = UUID()
            let task = Task { @MainActor [weak self] in
                defer {
                    self?.removeTask(withID: effectID, originID: originID)
                }

                for emission in emissions {
                    guard !Task.isCancelled, let self else { return }

                    let childTasks = self.spawnTasks(from: emission, originID: originID)
                    self.register(childTasks, originID: originID)

                    for childTask in childTasks.values {
                        await withTaskCancellationHandler {
                            await childTask.value
                        } onCancel: {
                            childTask.cancel()
                        }
                    }
                }
            }
            return [effectID: task]
        }
    }

    deinit {
        cancelAll()
    }
}
