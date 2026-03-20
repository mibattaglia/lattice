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
        let originID: UUID
    }

    struct RuntimeSendResult: Sendable {
        let originID: UUID
        let step: Step
        let startedEmissionCount: Int
    }

    struct FinishResult: Sendable {
        let didTimeout: Bool
        let inFlightEmissionCount: Int
    }

    private struct OriginCountWaiter {
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var onStep: (@MainActor (Step) -> Void)?

    private(set) var state: State

    private let interactor: AnyInteractor<State, Action>
    private let taskRegistry: EffectTaskRegistry

    private var inFlightEmissionCounts: [UUID: Int] = [:]
    private var originCountWaiters: [UUID: [OriginCountWaiter]] = [:]
    private var runtimeDrainWaiters: [CheckedContinuation<Void, Never>] = []

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
        onStep = handler
    }

    @discardableResult
    func send(
        _ action: Action,
        source: ActionSource = .sent,
        originID: UUID? = nil
    ) -> RuntimeSendResult {
        let resolvedOriginID = originID ?? UUID()
        let previousState = state
        let emission = interactor.interact(state: &state, action: action)

        let step = Step(
            action: action,
            source: source,
            previousState: previousState,
            currentState: state,
            originID: resolvedOriginID
        )
        onStep?(step)

        let startedEmissionCount = spawnTasks(
            from: emission,
            originID: resolvedOriginID
        )

        return RuntimeSendResult(
            originID: resolvedOriginID,
            step: step,
            startedEmissionCount: startedEmissionCount
        )
    }

    func finish(originID: UUID, timeout: Duration?) async -> FinishResult {
        if timeout == nil {
            await waitForOriginEmissionCount(originID, targetCount: 0)
            return FinishResult(
                didTimeout: false,
                inFlightEmissionCount: inFlightEmissionCount(originID: originID)
            )
        }

        let didTimeout = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                await self.waitForOriginEmissionCount(originID, targetCount: 0)
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout!)
                return true
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        return FinishResult(
            didTimeout: didTimeout,
            inFlightEmissionCount: inFlightEmissionCount(originID: originID)
        )
    }

    func finish(timeout: Duration?) async -> FinishResult {
        if timeout == nil {
            await waitForRuntimeToDrain()
            return FinishResult(
                didTimeout: false,
                inFlightEmissionCount: totalInFlightEmissionCount
            )
        }

        let didTimeout = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                await self.waitForRuntimeToDrain()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout!)
                return true
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        return FinishResult(
            didTimeout: didTimeout,
            inFlightEmissionCount: totalInFlightEmissionCount
        )
    }

    func hasInFlightEmissions() -> Bool {
        totalInFlightEmissionCount > 0
    }

    private func waitForOriginEmissionCount(
        _ originID: UUID,
        targetCount: Int
    ) async {
        guard inFlightEmissionCount(originID: originID) > targetCount else { return }

        await withCheckedContinuation { continuation in
            originCountWaiters[originID, default: []].append(
                OriginCountWaiter(
                    targetCount: targetCount,
                    continuation: continuation
                )
            )
        }
    }

    private func waitForRuntimeToDrain() async {
        guard totalInFlightEmissionCount > 0 else { return }

        await withCheckedContinuation { continuation in
            runtimeDrainWaiters.append(continuation)
        }
    }

    private func spawnTasks(
        from emission: Emission<Action>,
        originID: UUID
    ) -> Int {
        switch emission.kind {
        case .none:
            return 0

        case .action(let action):
            return send(
                action,
                source: .emitted,
                originID: originID
            ).startedEmissionCount

        case .perform(let work):
            let taskID = registerTrackedEmission(originID: originID)
            let task = Task { [weak self] in
                let action = await work()
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self?.finishTrackedEmission(originID: originID, taskID: taskID)
                    }
                    return
                }
                if let action {
                    await MainActor.run {
                        guard let self else { return }
                        _ = self.send(action, source: .emitted, originID: originID)
                    }
                }
                await MainActor.run {
                    self?.finishTrackedEmission(originID: originID, taskID: taskID)
                }
            }
            taskRegistry.insert(task: task, taskID: taskID, originID: originID)
            return 1

        case .observe(let stream):
            let taskID = registerTrackedEmission(originID: originID)
            let task = Task { [weak self] in
                let sourceStream = await stream()
                for await action in sourceStream {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        guard let self else { return }
                        _ = self.send(action, source: .emitted, originID: originID)
                    }
                }
                await MainActor.run {
                    self?.finishTrackedEmission(originID: originID, taskID: taskID)
                }
            }
            taskRegistry.insert(task: task, taskID: taskID, originID: originID)
            return 1

        case .merge(let emissions):
            return emissions.reduce(into: 0) { count, childEmission in
                count += spawnTasks(from: childEmission, originID: originID)
            }

        case .append(let emissions):
            guard !emissions.isEmpty else { return 0 }

            let taskID = registerTrackedEmission(originID: originID)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }

                for emission in emissions {
                    guard !Task.isCancelled else {
                        self.finishTrackedEmission(originID: originID, taskID: taskID)
                        return
                    }

                    _ = self.spawnTasks(from: emission, originID: originID)
                    await self.waitForOriginEmissionCount(originID, targetCount: 1)
                }

                self.finishTrackedEmission(originID: originID, taskID: taskID)
            }
            taskRegistry.insert(task: task, taskID: taskID, originID: originID)
            return 1
        }
    }

    private func registerTrackedEmission(originID: UUID) -> UUID {
        let taskID = UUID()
        inFlightEmissionCounts[originID, default: 0] += 1
        return taskID
    }

    private func finishTrackedEmission(originID: UUID, taskID: UUID) {
        taskRegistry.remove(taskID: taskID, originID: originID)

        if let count = inFlightEmissionCounts[originID], count > 1 {
            inFlightEmissionCounts[originID] = count - 1
        } else {
            inFlightEmissionCounts[originID] = nil
        }

        let currentCount = inFlightEmissionCount(originID: originID)
        if let waiters = originCountWaiters[originID] {
            let (ready, pending) = waiters.partitioned { currentCount <= $0.targetCount }
            originCountWaiters[originID] = pending.isEmpty ? nil : pending
            ready.forEach { $0.continuation.resume() }
        }

        if totalInFlightEmissionCount == 0 {
            let waiters = runtimeDrainWaiters
            runtimeDrainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func inFlightEmissionCount(originID: UUID) -> Int {
        inFlightEmissionCounts[originID, default: 0]
    }

    private var totalInFlightEmissionCount: Int {
        inFlightEmissionCounts.values.reduce(0, +)
    }
}

private extension Array {
    func partitioned(
        by predicate: (Element) -> Bool
    ) -> ([Element], [Element]) {
        var matching: [Element] = []
        var remaining: [Element] = []

        for element in self {
            if predicate(element) {
                matching.append(element)
            } else {
                remaining.append(element)
            }
        }

        return (matching, remaining)
    }
}
