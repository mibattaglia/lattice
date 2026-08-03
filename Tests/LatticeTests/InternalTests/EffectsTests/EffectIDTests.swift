import Testing

@testable import Lattice

private struct EffectIDTestError: Error {}

@Suite
@MainActor
struct EffectIDTests {

    @Test
    func isRunningTrueAfterLaunchFalseAfterCompletion() async throws {
        let gate = Gate()
        let (core, _) = makeHandleCore()
        let refresh = EffectID(name: "refresh")

        #expect(!refresh.isRunning)
        let task = try core.send(
            HandleAction { _, effects in
                effects.perform(id: refresh) { _ in
                    await gate.wait()
                }
            })

        // True immediately after `send` returns (registered before the synchronous head start).
        #expect(refresh.isRunning)
        gate.open()
        await task?.value
        #expect(!refresh.isRunning)
    }

    @Test
    func cancelFromEffectCancelsAllAttachedTasksAndReturnsOne() async throws {
        let recorder = Recorder()
        let (core, _) = makeHandleCore()
        let refresh = EffectID(name: "refresh")

        let launches = try core.send(
            HandleAction { _, effects in
                for index in 0..<2 {
                    effects.perform(id: refresh) { _ in
                        do {
                            try await Task.sleep(for: .seconds(100))
                        } catch {
                            recorder.record("cancelled \(index)")
                        }
                    }
                }
            })

        let canceller = try core.send(
            HandleAction { _, effects in
                effects.perform { _ in
                    let windDown = refresh.cancel()
                    recorder.record("returned=\(windDown != nil)")
                }
            })

        await launches?.value
        await canceller?.value
        #expect(recorder.events.sorted() == ["cancelled 0", "cancelled 1", "returned=true"])
        #expect(!refresh.isRunning)
    }

    @Test
    func cancelFromUpdatePhaseReportsIssueAndCancelsNothing() async throws {
        let gate = Gate()
        let (core, _) = makeHandleCore()
        let refresh = EffectID(name: "refresh")

        let task = try core.send(
            HandleAction { _, effects in
                effects.perform(id: refresh) { _ in
                    await gate.wait()
                }
            })

        withKnownIssue {
            try? core.send(
                HandleAction { _, _ in
                    #expect(refresh.cancel() == nil)
                })
        }

        // Nothing was cancelled.
        #expect(refresh.isRunning)
        gate.open()
        await task?.value
    }

    @Test
    func unboundCancelIsInert() {
        let refresh = EffectID(name: "refresh")
        #expect(refresh.cancel() == nil)
        #expect(!refresh.isRunning)
        #expect(refresh.taskError == nil)
    }

    @Test
    func callAsFunctionAwaitsCompletionAndRethrowsRecordedError() async throws {
        let (core, _) = makeHandleCore()
        let upload = EffectID(name: "upload")

        _ = try core.send(
            HandleAction { _, effects in
                effects.perform(id: upload) { _ in
                    await Task.yield()
                    throw EffectIDTestError()
                }
            })

        await #expect(throws: EffectIDTestError.self) {
            try await upload()
        }
        #expect(upload.taskError is EffectIDTestError)

        // A subsequent success clears the recorded error.
        _ = try core.send(
            HandleAction { _, effects in
                effects.perform(id: upload) { _ in
                    await Task.yield()
                }
            })
        try await upload()
        #expect(upload.taskError == nil)
    }

    @Test
    func taskErrorNeverRecordsCancellationError() async throws {
        let (core, _) = makeHandleCore()
        let upload = EffectID(name: "upload")

        let task = try core.send(
            HandleAction { _, effects in
                effects.perform(id: upload) { _ in
                    try await Task.sleep(for: .seconds(100))
                }
            })

        let canceller = try core.send(
            HandleAction { _, effects in
                effects.perform { _ in upload.cancel() }
            })
        await task?.value
        await canceller?.value

        #expect(upload.taskError == nil)
    }

    @Test
    func storageDeinitCancelsTheBoundBucket() async throws {
        let recorder = Recorder()
        let (core, effects) = makeHandleCore()
        var upload: EffectID? = EffectID(name: "upload")

        // Bind the identity's storage closures, then launch a task at the id's key directly
        // through the core (`perform` would retain the id inside its completion wrapper,
        // keeping the storage alive for the task's lifetime).
        effects._bindEffectID(upload!)
        let key = TaskKey(path: GraphPath(), location: .id(ObjectIdentifier(upload!.storage)))
        let task = try core.send(
            HandleAction { _, _ in
                core.launchEffect(path: key.path, location: key.location) {
                    do {
                        try await Task.sleep(for: .seconds(100))
                    } catch {
                        recorder.record("cancelled")
                    }
                }
            })

        #expect(core.hasTasks(at: key))
        upload = nil  // Storage.deinit → bound cancel closure → core bucket cancelled.
        await task?.value
        #expect(recorder.events == ["cancelled"])
        #expect(!core.hasTasks(at: key))
    }
}
