import Foundation
import Testing

@testable import Lattice

@Suite
@MainActor
struct EmissionExecutionTests {
    enum Action: Sendable, Equatable {
        case logged(String)
    }

    @MainActor
    final class Probe {
        var startedEffectIDs: [EffectID] = []
        var completedEffectIDs: [EffectID] = []
        var cancelledEffectIDs: [EffectID] = []
        var enqueuedActions: [Action] = []

        func spawn(
            _ emission: Emission<Action>,
            rootScopeID: SendScopeID = SendScopeID()
        ) -> [EffectID: Task<Void, Never>] {
            EmissionExecution.spawnTasks(
                from: emission,
                rootScopeID: rootScopeID,
                makeEffectID: { EffectID() },
                effectDidStart: { [weak self] effectID in
                    self?.startedEffectIDs.append(effectID)
                },
                effectDidComplete: { [weak self] effectID in
                    self?.completedEffectIDs.append(effectID)
                },
                effectDidCancel: { [weak self] effectID in
                    self?.cancelledEffectIDs.append(effectID)
                },
                enqueueEmittedAction: { [weak self] action, _ in
                    self?.enqueuedActions.append(action)
                }
            )
        }
    }

    actor EventRecorder {
        private var events: [String] = []

        func append(_ event: String) {
            events.append(event)
        }

        func snapshot() -> [String] {
            events
        }
    }

    @Test
    func performEnqueuesActionAndCompletes() async {
        let probe = Probe()

        let tasks = probe.spawn(
            .perform {
                .logged("performed")
            }
        )

        #expect(tasks.count == 1)
        #expect(probe.startedEffectIDs.count == 1)

        await wait(for: tasks)

        #expect(probe.enqueuedActions == [.logged("performed")])
        #expect(probe.completedEffectIDs.count == 1)
        #expect(probe.cancelledEffectIDs.isEmpty)
    }

    @Test
    func observeEmitsAllActionsInOrder() async {
        let probe = Probe()

        let tasks = probe.spawn(
            .observe {
                AsyncStream { continuation in
                    continuation.yield(.logged("stream-1"))
                    continuation.yield(.logged("stream-2"))
                    continuation.finish()
                }
            }
        )

        #expect(tasks.count == 1)

        await wait(for: tasks)

        #expect(probe.enqueuedActions == [.logged("stream-1"), .logged("stream-2")])
        #expect(probe.completedEffectIDs.count == 1)
        #expect(probe.cancelledEffectIDs.isEmpty)
    }

    @Test
    func mergeReturnsChildTasksAndCompletesEachEffect() async {
        let probe = Probe()

        let tasks = probe.spawn(
            .merge([
                .perform { .logged("merge-a") },
                .perform { .logged("merge-b") },
            ])
        )

        #expect(tasks.count == 2)
        #expect(probe.startedEffectIDs.count == 2)

        await wait(for: tasks)

        #expect(probe.enqueuedActions.count == 2)
        #expect(probe.enqueuedActions.contains(.logged("merge-a")))
        #expect(probe.enqueuedActions.contains(.logged("merge-b")))
        #expect(probe.completedEffectIDs.count == 2)
        #expect(probe.cancelledEffectIDs.isEmpty)
    }

    @Test
    func appendWaitsForObserveBeforeNextStep() async {
        let probe = Probe()

        let tasks = probe.spawn(
            .append(
                .observe {
                    AsyncStream { continuation in
                        continuation.yield(.logged("stream-1"))
                        continuation.yield(.logged("stream-2"))
                        continuation.finish()
                    }
                },
                .perform { .logged("after-stream") }
            )
        )

        #expect(tasks.count == 1)

        await wait(for: tasks)

        #expect(probe.enqueuedActions == [.logged("stream-1"), .logged("stream-2"), .logged("after-stream")])
        #expect(probe.completedEffectIDs.count == 1)
        #expect(probe.cancelledEffectIDs.isEmpty)
    }

    @Test
    func appendWaitsForInnerMergeBeforeNextStep() async throws {
        let probe = Probe()

        let tasks = probe.spawn(
            .append(
                .merge([
                    .perform { .logged("merge-a") },
                    .perform { .logged("merge-b") },
                ]),
                .perform { .logged("after-merge") }
            )
        )

        await wait(for: tasks)

        let actions = probe.enqueuedActions
        let afterMergeIndex = try #require(actions.firstIndex(of: .logged("after-merge")))

        #expect(actions[..<afterMergeIndex].contains(.logged("merge-a")))
        #expect(actions[..<afterMergeIndex].contains(.logged("merge-b")))
    }

    @Test
    func appendCancellationStopsRemainingSteps() async {
        let probe = Probe()
        let eventRecorder = EventRecorder()

        let tasks = probe.spawn(
            .append(
                .perform {
                    await eventRecorder.append("first-started")

                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return nil
                    }

                    await eventRecorder.append("first-finished")
                    return .logged("first")
                },
                .perform {
                    await eventRecorder.append("second-started")
                    return .logged("second")
                }
            )
        )

        #expect(tasks.count == 1)

        guard let parentTask = tasks.values.first else {
            Issue.record("Expected append emission to create a parent task")
            return
        }

        await waitUntil {
            let events = await eventRecorder.snapshot()
            return events.contains("first-started")
        }

        parentTask.cancel()
        await parentTask.value

        let events = await eventRecorder.snapshot()

        #expect(events.contains("first-started"))
        #expect(!events.contains("second-started"))
        #expect(!probe.enqueuedActions.contains(.logged("second")))
        #expect(probe.cancelledEffectIDs.count == 1)
    }

    private func wait(for tasks: [EffectID: Task<Void, Never>]) async {
        for task in tasks.values {
            await task.value
        }
    }

    private func waitUntil(
        iterations: Int = 200,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await condition() {
                return
            }
            await Task.yield()
        }
    }
}
